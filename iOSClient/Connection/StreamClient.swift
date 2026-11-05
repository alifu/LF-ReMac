import Foundation
import Network
import Observation
import RemoteCore

/// Connects to a Mac host, feeds received frames to the renderer and asks for keyframes when needed.
/// While connected it samples `stats` once per second and sends a latency ping with each sample.
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
    private static let statsInterval = Duration.seconds(1)

    private(set) var state: State = .idle
    private(set) var stats = StreamStats.empty
    let renderer: VideoRenderer

    @ObservationIgnored private let collector: StatsCollector
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    private let logger = AppLog.logger(category: "client")
    private var link: Link?

    init() {
        let collector = StatsCollector()
        self.collector = collector
        renderer = VideoRenderer(statsCollector: collector)
    }

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
        collector.reset()

        let link = Link(endpoint: endpoint, renderer: renderer, collector: collector)
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
        stopStatsLoop()
        link?.close()
        link = nil
        renderer.onKeyframeNeeded = nil
        stats = .empty
        if isActive { state = .idle }
    }

    private func apply(_ linkState: Link.State, name: String) {
        switch linkState {
        case .connected:
            state = .connected(name)
            startStatsLoop()
        case .closed(let reason):
            logger.info("Connection closed")
            stopStatsLoop()
            link = nil
            stats = .empty
            state = reason.map { .failed($0) } ?? .idle
        }
    }

    // MARK: - Statistics

    private func startStatsLoop() {
        stopStatsLoop()
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.statsInterval)
                guard !Task.isCancelled, let self else { return }
                self.sampleStats()
            }
        }
    }

    private func stopStatsLoop() {
        statsTask?.cancel()
        statsTask = nil
    }

    private func sampleStats() {
        link?.send(Frame.ping(sentAtMicros: MonotonicClock.nowMicros()))
        stats = collector.snapshot(now: .now)
    }
}

private extension Frame {
    static func keyframeRequest() -> Frame {
        Frame(type: .keyframeRequest, timestampMicros: 0, payload: Data())
    }

    /// Latency probe: the host echoes it back unchanged, so the timestamp survives the round trip.
    static func ping(sentAtMicros: UInt64) -> Frame {
        Frame(type: .ping, timestampMicros: sentAtMicros, payload: Data())
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
    private let collector: StatsCollector
    private let queue = DispatchQueue(label: "com.alifu.lfremac.client", qos: .userInteractive)
    private let logger = AppLog.logger(category: "link")
    private var decoder = FrameDecoder()
    private var isClosed = false

    init(endpoint: NWEndpoint, renderer: VideoRenderer, collector: StatsCollector) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        connection = NWConnection(to: endpoint, using: NWParameters(tls: nil, tcp: tcp))
        self.renderer = renderer
        self.collector = collector
    }

    func start(chunkBytes: Int) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            queue.async { self.handle(state: state, chunkBytes: chunkBytes) }
        }
        connection.start(queue: queue)
    }

    func send(_ frame: Frame) {
        queue.async { [self] in
            connection.send(content: FrameEncoder.encode(frame), completion: .contentProcessed { _ in })
        }
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
            collector.recordBytes(data.count)
            do {
                for frame in try decoder.append(data) { route(frame) }
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

    private func route(_ frame: Frame) {
        if frame.type == .ping {
            recordRoundTrip(sentAtMicros: frame.timestampMicros)
        } else {
            renderer.handle(frame)
        }
    }

    private func recordRoundTrip(sentAtMicros: UInt64) {
        let receivedMicros = MonotonicClock.nowMicros()
        guard let milliseconds = MonotonicClock.roundTripMilliseconds(
            sentMicros: sentAtMicros,
            receivedMicros: receivedMicros
        ) else { return }
        collector.recordRoundTrip(milliseconds: milliseconds)
    }

    private func finish(reason: String?) {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
        onStateChange?(.closed(reason: reason))
    }
}
