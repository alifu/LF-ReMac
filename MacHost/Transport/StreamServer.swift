import Foundation
import Network
import OSLog
import RemoteCore

/// Things the host app reacts to; the server itself never touches capture or encoding.
enum StreamServerEvent: Equatable, Sendable {
    case ready(port: UInt16)
    case clientConnected
    case clientDisconnected
    /// A validated input event from the client. Whether to act on it is the host session's decision.
    case input(InputEvent)
    /// The encoder should emit a fresh keyframe (new client, client request, or client fell behind).
    case keyframeNeeded
    case failed(String)
}

/// TCP server that streams `Frame`s to a single client (the paired iPhone) and advertises itself over Bonjour.
///
/// All mutable state lives on `queue`; public methods are safe to call from any thread.
/// A newly connected client replaces the previous one. Phase 4 adds TLS and pairing on top of this.
final class StreamServer: @unchecked Sendable {
    static let bonjourServiceType = NetworkDefaults.bonjourServiceType
    static let defaultPort = NWEndpoint.Port(rawValue: NetworkDefaults.port) ?? .any
    private static let receiveChunkBytes = 64 * 1024

    let events: AsyncStream<StreamServerEvent>

    private let continuation: AsyncStream<StreamServerEvent>.Continuation
    private let queue = DispatchQueue(label: "com.alifu.lfremac.server", qos: .userInteractive)
    private let logger = AppLog.logger(category: "server")
    private let serviceType: String?
    private let requestedPort: NWEndpoint.Port
    private var listener: NWListener?
    private var session: ClientSession?

    /// - Parameters:
    ///   - serviceType: Bonjour type to advertise; pass nil to skip advertising (used by tests).
    ///   - port: `.any` lets the system choose; the chosen port is reported in `.ready`.
    init(serviceType: String? = StreamServer.bonjourServiceType, port: NWEndpoint.Port = .any) {
        let (stream, continuation) = AsyncStream<StreamServerEvent>.makeStream(bufferingPolicy: .unbounded)
        self.events = stream
        self.continuation = continuation
        self.serviceType = serviceType
        self.requestedPort = port
    }

    func start() throws {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        let listener = try NWListener(using: NWParameters(tls: nil, tcp: tcp), on: requestedPort)
        if let serviceType {
            listener.service = NWListener.Service(type: serviceType)
        }
        listener.stateUpdateHandler = { [weak self] state in self?.handleListener(state: state) }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        queue.sync { self.listener = listener }
        listener.start(queue: queue)
    }

    func stop() {
        queue.async {
            self.session?.connection.cancel()
            self.session = nil
            self.listener?.cancel()
            self.listener = nil
            self.continuation.finish()
        }
    }

    /// Sends `frame` to the current client if its send policy allows; otherwise drops it.
    func broadcast(_ frame: Frame) {
        queue.async { [self] in
            guard let session, session.isReady else { return }
            switch session.gate.decide(for: frame) {
            case .send:
                send(frame, on: session)
            case .drop:
                break
            case .dropAndRequestKeyframe:
                logger.notice("Client is falling behind; dropping video until next keyframe")
                continuation.yield(.keyframeNeeded)
            }
        }
    }

    // MARK: - Listener

    private func handleListener(state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener?.port?.rawValue {
                logger.info("Listening on port \(port)")
                continuation.yield(.ready(port: port))
            }
        case .failed(let error):
            logger.error("Listener failed: \(error.localizedDescription, privacy: .public)")
            continuation.yield(.failed(error.localizedDescription))
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        session?.connection.cancel()
        let session = ClientSession(connection: connection)
        self.session = session
        connection.stateUpdateHandler = { [weak self, weak session] state in
            guard let self, let session else { return }
            handleConnection(state: state, session: session)
        }
        connection.start(queue: queue)
    }

    // MARK: - Connection

    private func handleConnection(state: NWConnection.State, session: ClientSession) {
        switch state {
        case .ready:
            guard self.session === session else { return }
            session.isReady = true
            logger.info("Client connected")
            continuation.yield(.clientConnected)
            continuation.yield(.keyframeNeeded)
            receive(on: session)
        case .failed, .cancelled:
            guard self.session === session else { return }
            self.session = nil
            logger.info("Client disconnected")
            continuation.yield(.clientDisconnected)
        default:
            break
        }
    }

    private func receive(on session: ClientSession) {
        session.connection.receive(minimumIncompleteLength: 1, maximumLength: Self.receiveChunkBytes) {
            [weak self, weak session] data, _, isComplete, error in
            guard let self, let session else { return }
            queue.async { self.handleReceived(data, isComplete: isComplete, error: error, session: session) }
        }
    }

    private func handleReceived(_ data: Data?, isComplete: Bool, error: NWError?, session: ClientSession) {
        guard self.session === session else { return }
        if let data, !data.isEmpty {
            do {
                for frame in try session.decoder.append(data) { handle(frame, from: session) }
            } catch {
                logger.error("Protocol error from client: \(String(describing: error), privacy: .public)")
                session.connection.cancel()
                return
            }
        }
        if let error {
            logger.error("Receive failed: \(error.localizedDescription, privacy: .public)")
            session.connection.cancel()
        } else if isComplete {
            session.connection.cancel()
        } else {
            receive(on: session)
        }
    }

    private func handle(_ frame: Frame, from session: ClientSession) {
        switch frame.type {
        case .keyframeRequest:
            continuation.yield(.keyframeNeeded)
        case .ping:
            // Echo for round-trip latency measurement; goes through the gate to keep its pending count balanced.
            if session.gate.decide(for: frame) == .send { send(frame, on: session) }
        case .input:
            forwardInput(frame)
        case .videoConfig, .videoFrame, .pairRequest, .pairResponse:
            break
        }
    }

    private func forwardInput(_ frame: Frame) {
        do {
            continuation.yield(.input(try InputEventCoding.event(from: frame)))
        } catch {
            logger.error("Dropped invalid input event: \(String(describing: error), privacy: .public)")
        }
    }

    private func send(_ frame: Frame, on session: ClientSession) {
        let data = FrameEncoder.encode(frame)
        session.connection.send(content: data, completion: .contentProcessed { [weak self, weak session] error in
            guard let self, let session else { return }
            queue.async {
                session.gate.sendCompleted()
                if let error {
                    self.logger.error("Send failed: \(error.localizedDescription, privacy: .public)")
                    session.connection.cancel()
                }
            }
        })
    }
}

/// Per-connection state; only touched on the server queue.
private final class ClientSession: @unchecked Sendable {
    let connection: NWConnection
    var decoder = FrameDecoder()
    var gate = ClientSendGate()
    var isReady = false

    init(connection: NWConnection) {
        self.connection = connection
    }
}
