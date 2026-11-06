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
    /// Set while the stream dropped by itself and the client is redialling; `state` stays
    /// `.connected` so the picture stays on screen under a banner.
    private(set) var reconnect: ReconnectStatus?
    /// The Mac's displays, once it has reported them; empty for a Mac that does not (or before it does).
    private(set) var displays = HostDisplays.none
    /// Sound from the Mac is on. Off for a Mac never heard before; the choice is remembered per Mac.
    private(set) var isAudioOn = false
    let renderer: VideoRenderer

    @ObservationIgnored private let collector: StatsCollector
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private let credentials: PhoneCredentials
    @ObservationIgnored private let audioPlayer = AudioPlayer()
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var currentHost: PairedHost?
    private let logger = AppLog.logger(category: "client")
    private var link: StreamLink?
    @ObservationIgnored private var attempts = ConnectionAttempts(candidates: [])
    @ObservationIgnored private var reconnectPolicy = ReconnectPolicy()
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var lastCandidates: [NWEndpoint] = []
    @ObservationIgnored private var currentEndpoint: NWEndpoint?

    init(credentials: PhoneCredentials, defaults: UserDefaults = .standard) {
        self.credentials = credentials
        self.defaults = defaults
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
        lastCandidates = candidates
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
        currentEndpoint = endpoint
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
        link.onHostInfo = { [weak self, weak link] info in
            Task { @MainActor in
                guard let self, let link, self.link === link else { return }
                self.displays = HostDisplays(info)
                self.rememberWakeAddresses(info.wakeMACs, for: host)
            }
        }
        link.onAudio = { [audioPlayer] frame in audioPlayer.handle(frame) }
        self.link = link
        link.start(chunkBytes: Self.receiveChunkBytes)
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectPolicy = ReconnectPolicy()
        reconnect = nil
        attempts = ConnectionAttempts(candidates: [])
        stopStatsLoop()
        link?.close()
        link = nil
        audioPlayer.setActive(false)
        isAudioOn = false
        currentHost = nil
        renderer.onKeyframeNeeded = nil
        renderer.onVideoSizeChange = nil
        stats = .empty
        videoSize = .zero
        displays = .none
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

    /// Asks the Mac to stream another display. The picker updates when the Mac reports the change.
    func selectDisplay(_ display: DisplayInfo) {
        guard case .connected = state, let link, displays.canChoose, !displays.isSelected(display) else { return }
        do {
            link.send(try SessionMessageCoding.frame(
                for: SelectDisplay(displayID: display.id), timestampMicros: MonotonicClock.nowMicros()))
        } catch {
            logger.error("Could not encode display choice: \(String(describing: error), privacy: .public)")
        }
    }

    /// Turns the Mac's sound on or off and remembers the choice for this Mac.
    func setAudio(_ enabled: Bool) {
        guard case .connected = state, let host = currentHost else { return }
        defaults.set(enabled, forKey: Self.audioKey(for: host))
        applyAudio(enabled)
    }

    private func applyAudio(_ enabled: Bool) {
        guard let link else { return }
        do {
            link.send(try SessionMessageCoding.frame(for: AudioControl(enabled: enabled), timestampMicros: MonotonicClock.nowMicros()))
        } catch {
            logger.error("Could not encode audio choice: \(String(describing: error), privacy: .public)")
            return
        }
        isAudioOn = enabled
        audioPlayer.setActive(enabled)
    }

    /// A new (or re-established) stream starts silent on the Mac; bring back what the user chose last time.
    private func restoreAudio(for host: PairedHost) {
        currentHost = host
        applyAudio(defaults.bool(forKey: Self.audioKey(for: host)))
    }

    private static func audioKey(for host: PairedHost) -> String {
        "audioEnabled.\(host.fingerprint)"
    }

    #if DEBUG
    /// Screenshot mode only: shows the connected UI with made-up values and no network.
    func demoConnect(hostName: String, stats: StreamStats, displays: HostDisplays) {
        state = .connected(hostName)
        self.stats = stats
        self.displays = displays
        videoSize = CGSize(width: 2560, height: 1440)
        isAudioOn = true
    }
    #endif

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
            reconnectPolicy = ReconnectPolicy()
            reconnect = nil
            state = .connected(host.name)
            startStatsLoop()
            restoreAudio(for: host)
            remember(address, for: host)
        case .closed(let summary):
            logger.info("Connection closed")
            stopStatsLoop()
            audioPlayer.setActive(false)
            isAudioOn = false
            link = nil
            stats = .empty
            let (step, attempts) = attempts.next(after: summary)
            self.attempts = attempts
            if case .dial = step {
                logger.notice("Trying the paired Mac's next address")
                perform(step, host: host)
            } else if shouldReconnect(after: summary) {
                scheduleReconnect(host: host, fallback: step)
            } else {
                perform(step, host: host)
            }
        }
    }

    // MARK: - Reconnecting

    /// Redial only a stream that was up (or a reconnect cycle that is already running).
    private func shouldReconnect(after summary: LinkCloseSummary) -> Bool {
        let isUp: Bool
        if case .connected = state { isUp = true } else { isUp = false }
        guard isUp || reconnect != nil else { return false }
        return ReconnectPolicy.isRecoverable(summary, wasEstablished: reconnect == nil)
    }

    /// Waits out the next backoff, then redials; gives up with `fallback` once the tries are used.
    private func scheduleReconnect(host: PairedHost, fallback: ConnectionAttempts.Step) {
        guard let next = reconnectPolicy.next() else {
            logger.notice("Giving up reconnecting")
            reconnect = nil
            state = .failed("Lost the connection to \(host.name) and could not get it back.")
            return
        }
        reconnectPolicy = next.policy
        reconnect = next.status
        logger.notice("Reconnecting, try \(next.status.attempt) of \(next.status.total)")
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: next.delay)
            guard !Task.isCancelled, let self else { return }
            self.redial(host)
        }
    }

    private func redial(_ host: PairedHost) {
        // Try the address that worked last, then the rest; use the stored Mac in case its address changed.
        let current = credentials.hostStore.peer(with: host.fingerprint) ?? host
        let candidates = ([currentEndpoint].compactMap { $0 } + lastCandidates
            + [PairedHostTarget.lastKnownEndpoint(of: current)].compactMap { $0 })
            .reduce(into: [NWEndpoint]()) { if !$0.contains($1) { $0.append($1) } }
        let (step, attempts) = ConnectionAttempts(candidates: candidates).start()
        self.attempts = attempts
        if case .dial(let endpoint) = step { dial(endpoint, host: host) } else { scheduleReconnect(host: host, fallback: step) }
    }

    /// Keeps the Mac's hardware addresses for Wake-on-LAN. A report with none never erases what is stored.
    private func rememberWakeAddresses(_ reported: [String], for host: PairedHost) {
        guard let current = credentials.hostStore.peer(with: host.fingerprint) else { return }
        let updated = current.withWakeMACs(reported)
        guard !updated.wakeAddresses.isEmpty, updated.wakeMACs != current.wakeMACs else { return }
        do {
            try credentials.hostStore.add(updated)
        } catch {
            logger.error("Could not save the Mac's wake addresses: \(String(describing: error), privacy: .public)")
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
