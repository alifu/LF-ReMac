import Foundation
import Network
import Observation
import RemoteCore

/// Connects to a paired Mac over pinned mutual TLS 1.3, feeds received frames to the renderer and
/// asks for keyframes when needed. There is no plaintext path: only a Mac whose key matches the
/// stored `PairedHost.fingerprint` is accepted, and the Mac in turn only accepts paired iPhones.
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
    /// Pixel size of the Mac's picture, known once the first video config arrives.
    private(set) var videoSize: CGSize = .zero
    let renderer: VideoRenderer

    @ObservationIgnored private let collector: StatsCollector
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private let credentials: PhoneCredentials
    private let logger = AppLog.logger(category: "client")
    private var link: StreamLink?
    @ObservationIgnored private var attempts = ConnectionAttempts(candidates: [])

    init(credentials: PhoneCredentials) {
        self.credentials = credentials
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

    /// Connects to `host`, trying every Bonjour service with its name and then its last known
    /// address until one presents the pinned key and accepts this iPhone.
    func connect(to host: PairedHost, discovered: [DiscoveredHost]) {
        connect(to: host, candidates: PairedHostTarget.candidates(for: host, discovered: discovered))
    }

    /// Connects to `host` at `endpoint`, falling back to its last known address, pinning its key.
    func connect(to endpoint: NWEndpoint, host: PairedHost) {
        connect(to: host, candidates: PairedHostTarget.candidates(preferring: endpoint, for: host))
    }

    /// Tries `candidates` in order; a failed attempt (wrong key, unreachable, ...) moves on.
    func connect(to host: PairedHost, candidates: [NWEndpoint]) {
        disconnect()
        state = .connecting(host.name)
        let (step, attempts) = ConnectionAttempts(candidates: candidates).start()
        self.attempts = attempts
        perform(step, host: host)
    }

    private func perform(_ step: ConnectionAttempts.Step, host: PairedHost) {
        switch step {
        case .dial(let endpoint):
            dial(endpoint, host: host)
        case .giveUp(let message):
            state = message.map { .failed($0) } ?? .idle
        }
    }

    private func dial(_ endpoint: NWEndpoint, host: PairedHost) {
        renderer.reset()
        collector.reset()
        guard let link = makeLink(endpoint: endpoint, host: host) else { return }
        link.onStateChange = { [weak self, weak link] newState in
            Task { @MainActor in
                guard let self, let link, self.link === link else { return }
                self.apply(newState, host: host)
            }
        }
        renderer.onKeyframeNeeded = { [weak link] in link?.send(Frame.keyframeRequest()) }
        renderer.onVideoSizeChange = { [weak self] size in
            Task { @MainActor in self?.videoSize = size }
        }
        self.link = link
        link.start(chunkBytes: Self.receiveChunkBytes)
    }

    func disconnect() {
        attempts = ConnectionAttempts(candidates: [])
        stopStatsLoop()
        link?.close()
        link = nil
        renderer.onKeyframeNeeded = nil
        renderer.onVideoSizeChange = nil
        stats = .empty
        videoSize = .zero
        if isActive { state = .idle }
    }

    /// Sends a touch or keyboard event to the Mac; dropped silently when not connected.
    func send(_ event: InputEvent) {
        guard case .connected = state, let link else { return }
        do {
            link.send(try InputEventCoding.frame(for: event, timestampMicros: MonotonicClock.nowMicros()))
        } catch {
            logger.error("Could not encode input: \(String(describing: error), privacy: .public)")
        }
    }

    private func makeLink(endpoint: NWEndpoint, host: PairedHost) -> StreamLink? {
        do {
            let identity = try credentials.identity()
            return try StreamLink(
                endpoint: endpoint, identity: identity, pinnedHost: host.fingerprint, renderer: renderer, collector: collector
            )
        } catch {
            logger.error("Cannot prepare a secure connection: \(String(describing: error), privacy: .public)")
            state = .failed("This iPhone's security key could not be loaded from the Keychain.")
            return nil
        }
    }

    private func apply(_ linkState: StreamLink.State, host: PairedHost) {
        switch linkState {
        case .connected(let address):
            attempts = ConnectionAttempts(candidates: [])
            state = .connected(host.name)
            startStatsLoop()
            remember(address, for: host)
        case .closed(let summary):
            logger.info("Connection closed")
            stopStatsLoop()
            link = nil
            stats = .empty
            let (step, attempts) = attempts.next(after: summary)
            self.attempts = attempts
            if case .dial = step { logger.notice("Trying the paired Mac's next address") }
            perform(step, host: host)
        }
    }

    /// Saves where the (verified, accepting) Mac was reached, for the next connection.
    private func remember(_ address: RemoteAddress, for host: PairedHost) {
        guard let reachedHost = address.host, let reachedPort = address.port,
              let current = credentials.hostStore.peer(with: host.fingerprint),
              current.lastKnownHost != reachedHost || current.lastKnownPort != reachedPort else { return }
        do {
            try credentials.hostStore.add(current.reached(at: reachedHost, port: reachedPort))
        } catch {
            logger.error("Could not save the Mac's address: \(String(describing: error), privacy: .public)")
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
