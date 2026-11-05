import Foundation
import Network
import Observation
import RemoteCore

/// Connects to a Mac host, feeds received frames to the renderer and asks for keyframes when needed.
@MainActor
@Observable
final class StreamClient {
    enum State: Equatable {
        case idle
        case connecting(String)
        case connected(String)
        case failed(String)
    }

    private static let receiveChunkBytes = 256 * 1024

    private(set) var state: State = .idle
    let renderer = VideoRenderer()

    private let logger = AppLog.logger(category: "client")
    private var link: Link?

    var isActive: Bool {
        switch state {
        case .connecting, .connected: true
        case .idle, .failed: false
        }
    }

    func connect(to endpoint: NWEndpoint, name: String) {
        disconnect()
        state = .connecting(name)
        renderer.reset()

        let link = Link(endpoint: endpoint, renderer: renderer)
        link.onStateChange = { [weak self, weak link] newState in
            Task { @MainActor in
                guard let self, let link, self.link === link else { return }
                self.apply(newState, name: name)
            }
        }
        renderer.onKeyframeNeeded = { [weak link] in link?.send(Frame.keyframeRequest()) }
        self.link = link
        link.start(chunkBytes: Self.receiveChunkBytes)
    }

    func disconnect() {
        link?.close()
        link = nil
        renderer.onKeyframeNeeded = nil
        if isActive { state = .idle }
    }

    private func apply(_ linkState: Link.State, name: String) {
        switch linkState {
        case .connected:
            state = .connected(name)
        case .closed(let reason):
            logger.info("Connection closed")
            link = nil
            state = reason.map { .failed($0) } ?? .idle
        }
    }
}

private extension Frame {
    static func keyframeRequest() -> Frame {
        Frame(type: .keyframeRequest, timestampMicros: 0, payload: Data())
    }
}

/// One TCP connection. Everything except `onStateChange` assignment runs on its private queue.
private final class Link: @unchecked Sendable {
    enum State: Sendable {
        case connected
        case closed(reason: String?)
    }

    var onStateChange: (@Sendable (State) -> Void)?

    private let connection: NWConnection
    private let renderer: VideoRenderer
    private let queue = DispatchQueue(label: "com.alifu.lfremac.client", qos: .userInteractive)
    private let logger = AppLog.logger(category: "link")
    private var decoder = FrameDecoder()
    private var isClosed = false

    init(endpoint: NWEndpoint, renderer: VideoRenderer) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        connection = NWConnection(to: endpoint, using: NWParameters(tls: nil, tcp: tcp))
        self.renderer = renderer
    }

    func start(chunkBytes: Int) {
        connection.stateUpdateHandler = { [weak self] state in
            self?.queue.async { self?.handle(state: state, chunkBytes: chunkBytes) }
        }
        connection.start(queue: queue)
    }

    func send(_ frame: Frame) {
        connection.send(content: FrameEncoder.encode(frame), completion: .contentProcessed { _ in })
    }

    func close() {
        queue.async { [self] in
            isClosed = true
            connection.cancel()
        }
    }

    private func handle(state: NWConnection.State, chunkBytes: Int) {
        switch state {
        case .ready:
            onStateChange?(.connected)
            receive(chunkBytes: chunkBytes)
        case .failed(let error):
            finish(reason: error.localizedDescription)
        case .waiting(let error):
            // Network.framework parks refused/unreachable connections here instead of failing; surface it.
            logger.notice("Cannot reach host: \(error.localizedDescription, privacy: .public)")
            finish(reason: "Cannot reach the Mac: \(error.localizedDescription)")
        case .cancelled:
            finish(reason: nil)
        default:
            break
        }
    }

    private func receive(chunkBytes: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: chunkBytes) { [weak self] data, _, done, error in
            guard let self else { return }
            queue.async { self.handleReceived(data, isComplete: done, error: error, chunkBytes: chunkBytes) }
        }
    }

    private func handleReceived(_ data: Data?, isComplete: Bool, error: NWError?, chunkBytes: Int) {
        guard !isClosed else { return }
        if let data, !data.isEmpty {
            do {
                for frame in try decoder.append(data) { renderer.handle(frame) }
            } catch {
                logger.error("Protocol error: \(String(describing: error), privacy: .public)")
                finish(reason: "The Mac sent data this app does not understand.")
                return
            }
        }
        if let error {
            finish(reason: error.localizedDescription)
        } else if isComplete {
            finish(reason: "The Mac closed the connection.")
        } else {
            receive(chunkBytes: chunkBytes)
        }
    }

    private func finish(reason: String?) {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
        onStateChange?(.closed(reason: reason))
    }
}
