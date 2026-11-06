import Foundation
import Network
import OSLog
import RemoteCore

/// Things the host app reacts to; the server itself never touches capture or encoding.
enum StreamServerEvent: Equatable, Sendable {
    case ready(port: UInt16)
    /// A paired iPhone became the active session.
    case clientConnected(DeviceFingerprint)
    /// The active session ended (closed, replaced, revoked).
    case clientDisconnected(DeviceFingerprint)
    /// A validated input event from the active, paired session. Acting on it is the host's decision.
    case input(InputEvent)
    /// The active client's hello: what it can handle beyond the Phase 1-6 protocol.
    case clientHello(PeerCapabilities)
    /// The active client asked to stream this display (a validated display UUID; may no longer exist).
    case displaySelected(String)
    /// The encoder should emit a fresh keyframe (new client, client request, or client fell behind).
    case keyframeNeeded
    /// The active client's connection is backed up; the encoder should lower its bitrate.
    case congestion
    /// A new iPhone proved knowledge of the pairing secret and was saved to the store.
    case devicePaired(PairedDevice)
    case pairingFailed(PairingRejection)
    case failed(String)
}

/// Mutual-TLS 1.3 server that streams `Frame`s to one paired iPhone and advertises over Bonjour.
///
/// Authorization (see `ConnectionAuthorizer`): the TLS verify block admits a client key only if it
/// is paired or a pairing window is open; once `.ready`, the verified fingerprint decides the role.
/// Only a paired connection can become the active session (a newer one replaces the older); an
/// unpaired one is kept apart, capped (in total and per remote address), timed out, gets no video and may only send `pairRequest`.
///
/// All mutable state lives on `queue`; public methods are safe to call from any thread.
final class StreamServer: @unchecked Sendable {
    static let bonjourServiceType = NetworkDefaults.bonjourServiceType
    static let defaultPort = NWEndpoint.Port(rawValue: NetworkDefaults.port) ?? .any

    let events: AsyncStream<StreamServerEvent>

    let continuation: AsyncStream<StreamServerEvent>.Continuation
    let queue = DispatchQueue(label: "com.alifu.lfremac.server", qos: .userInteractive)
    let logger = AppLog.logger(category: "server")
    let identity: DeviceIdentity
    let store: PairedDeviceStore
    let coordinator: PairingCoordinator
    let responder: PairingResponder
    let limits: StreamServerLimits
    private let serviceType: String?
    private let requestedPort: NWEndpoint.Port
    private var listener: NWListener?
    private var networkPolicy: NetworkPolicy

    // Queue-confined connection registry.
    var active: PeerConnection?
    var others: [ObjectIdentifier: PeerConnection] = [:]

    /// - Parameters:
    ///   - serviceType: Bonjour type to advertise; pass nil to skip advertising (used by tests).
    ///   - port: `.any` lets the system choose; the chosen port is reported in `.ready`.
    init(
        identity: DeviceIdentity,
        store: PairedDeviceStore,
        coordinator: PairingCoordinator,
        hostName: String,
        serviceType: String? = StreamServer.bonjourServiceType,
        port: NWEndpoint.Port = .any,
        limits: StreamServerLimits = .standard,
        networkPolicy: NetworkPolicy = .lanOnly
    ) {
        let (stream, continuation) = AsyncStream<StreamServerEvent>.makeStream(bufferingPolicy: .unbounded)
        self.events = stream
        self.continuation = continuation
        self.identity = identity
        self.store = store
        self.coordinator = coordinator
        self.responder = PairingResponder(coordinator: coordinator, store: store, hostName: hostName)
        self.limits = limits
        self.networkPolicy = networkPolicy
        self.serviceType = serviceType
        self.requestedPort = port
    }

    func start() throws {
        let listener = try NWListener(using: try tlsParameters(), on: requestedPort)
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
            self.active?.cancel()
            self.active = nil
            self.others.values.forEach { $0.cancel() }
            self.others = [:]
            self.listener?.cancel()
            self.listener = nil
            self.continuation.finish()
        }
    }

    /// Sends `frame` to the active paired session if its send policy allows; otherwise drops it.
    func broadcast(_ frame: Frame) {
        queue.async { [self] in
            guard let session = active, case .paired = session.role else { return }
            switch session.gate.decide(for: frame) {
            case .send:
                send(frame, on: session)
            case .drop:
                break
            case .requestKeyframe:
                continuation.yield(.keyframeNeeded)
            case .dropAndRequestKeyframe:
                logger.notice("Client is falling behind; dropping video until next keyframe")
                continuation.yield(.keyframeNeeded)
                continuation.yield(.congestion)
            }
        }
    }

    /// Immediately drops every connection authenticated as `fingerprint` (call after revoking it).
    func disconnect(deviceWith fingerprint: DeviceFingerprint) {
        queue.async { [self] in
            if let session = active, session.fingerprint == fingerprint {
                endActiveSession(session)
            }
            others.values.filter { $0.fingerprint == fingerprint }.forEach { $0.cancel() }
        }
    }

    /// Changes which networks may connect; connections from newly disallowed addresses are dropped.
    func setNetworkPolicy(_ policy: NetworkPolicy) {
        queue.async { [self] in
            networkPolicy = policy
            if let session = active, !policy.allows(session.connection.endpoint) { endActiveSession(session) }
            others.values.filter { !policy.allows($0.connection.endpoint) }.forEach { $0.cancel() }
        }
    }

    /// Drops unpaired connections waiting to pair (call when the pairing window closes).
    func closePairingConnections() {
        queue.async { [self] in
            others.values.filter(\.isPairing).forEach { $0.cancel() }
        }
    }

    // MARK: - Listener

    private func tlsParameters() throws -> NWParameters {
        let store = store
        let coordinator = coordinator
        // Runs on the TLS verify queue: fast, thread-safe, fails closed on store errors.
        return try TLSParameters.server(identity: identity) { fingerprint in
            store.contains(fingerprint) || coordinator.isOpen
        }
    }

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
        guard networkPolicy.allows(connection.endpoint) else {
            logger.notice("Refusing a connection from outside the allowed networks")
            connection.cancel()
            return
        }
        let peer = PeerConnection(connection: connection)
        let inProgress = others.values.filter { $0.role == .handshaking }.map(\.source)
        let admission = HandshakeAdmission.decide(for: peer.source, inProgress: inProgress, limits: limits)
        guard admission == .admitted else {
            logger.notice("Refusing a connection: \(String(describing: admission), privacy: .public)")
            connection.cancel()
            return
        }
        others[ObjectIdentifier(peer)] = peer
        connection.stateUpdateHandler = { [weak self, weak peer] state in
            guard let self, let peer else { return }
            handleConnection(state: state, peer: peer)
        }
        peer.setDeadline(after: limits.handshakeTimeout, on: queue)
        connection.start(queue: queue)
    }
}
