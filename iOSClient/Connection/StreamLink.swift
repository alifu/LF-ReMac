import Foundation
import Network
import os
import RemoteCore

/// One pinned mutual-TLS connection to a paired Mac. Everything except `onStateChange`
/// assignment runs on its private queue. `.connected` is reported on the first frame from the Mac.
///
/// The key is checked twice: by the TLS verify block, and again at `.ready` against the verified
/// peer certificate of this very connection (defence in depth: no frame is sent otherwise).
final class StreamLink: @unchecked Sendable {
    enum State: Sendable {
        /// `address` is where the Mac was actually reached (nil if unknown).
        case connected(address: RemoteAddress)
        case closed(LinkCloseSummary)
    }

    var onStateChange: (@Sendable (State) -> Void)?

    private let connection: NWConnection
    private let pinnedHost: DeviceFingerprint
    private let renderer: VideoRenderer
    private let collector: StatsCollector
    private let wrongHostKey: WrongHostKeyFlag
    private let queue = DispatchQueue(label: "com.alifu.lfremac.client", qos: .userInteractive)
    private let logger = AppLog.logger(category: "link")
    private var decoder = FrameDecoder(allowedTypes: ProtocolTypes.clientAcceptsFromHost)
    private var history = LinkHistory()
    private var readyAt: ContinuousClock.Instant?
    private var isClosed = false

    /// Fails if the identity cannot be used for TLS.
    init(
        endpoint: NWEndpoint, identity: DeviceIdentity, pinnedHost: DeviceFingerprint,
        renderer: VideoRenderer, collector: StatsCollector
    ) throws(TLSConfigurationError) {
        let flag = WrongHostKeyFlag()
        let parameters = try TLSParameters.client(identity: identity) { fingerprint in
            let isPinned = fingerprint == pinnedHost
            if !isPinned { flag.set() }
            return isPinned
        }
        connection = NWConnection(to: endpoint, using: parameters)
        self.pinnedHost = pinnedHost
        wrongHostKey = flag
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
            guard TLSParameters.peerFingerprint(of: connection) == pinnedHost else {
                logger.error("Connected peer does not present the paired Mac's key; closing")
                wrongHostKey.set()
                finish(.failed("Security key mismatch", isTLS: true))
                return
            }
            // TLS 1.3: `.ready` does not mean the Mac accepted our key yet. Ask for an echo and
            // report `.connected` only when the first frame arrives (only paired iPhones get one).
            readyAt = .now
            history.reachedReady = true
            connection.send(content: FrameEncoder.encode(Self.probe()), completion: .contentProcessed { _ in })
            receive(chunkBytes: chunkBytes)
        case .failed(let error):
            finish(LinkCloseClassifier.cause(for: error, parked: false))
        case .waiting(let error):
            // Network.framework parks refused/unreachable connections here instead of failing; surface it.
            logger.notice("Cannot reach host: \(error.localizedDescription, privacy: .public)")
            finish(LinkCloseClassifier.cause(for: error, parked: true))
        case .cancelled:
            finish(.local)
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
                finish(.protocolError)
                return
            }
        }
        if let error {
            finish(LinkCloseClassifier.cause(for: error, parked: false))
        } else if isComplete {
            finish(.closedByHost)
        } else {
            receive(chunkBytes: chunkBytes)
        }
    }

    private func route(_ frame: Frame) {
        if !history.receivedFrame {
            history.receivedFrame = true
            onStateChange?(.connected(address: RemoteAddress(connection.currentPath?.remoteEndpoint)))
        }
        if frame.type == .ping {
            recordRoundTrip(sentAtMicros: frame.timestampMicros)
        } else {
            renderer.handle(frame)
        }
    }

    private static func probe() -> Frame {
        Frame(type: .ping, timestampMicros: MonotonicClock.nowMicros(), payload: Data())
    }

    private func recordRoundTrip(sentAtMicros: UInt64) {
        let receivedMicros = MonotonicClock.nowMicros()
        guard let milliseconds = MonotonicClock.roundTripMilliseconds(
            sentMicros: sentAtMicros,
            receivedMicros: receivedMicros
        ) else { return }
        collector.recordRoundTrip(milliseconds: milliseconds)
    }

    private func finish(_ cause: LinkCloseCause) {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
        history.sawWrongHostKey = wrongHostKey.isSet
        history.secondsAfterReady = readyAt.map { (ContinuousClock.now - $0).timeInterval }
        onStateChange?(.closed(LinkCloseSummary(
            message: LinkCloseClassifier.message(for: cause, history: history),
            canTryAnotherAddress: cause != .local && !history.receivedFrame,
            sawWrongHostKey: history.sawWrongHostKey,
            closedByHost: cause == .closedByHost
        )))
    }
}

/// Set from the TLS verify queue, read on the link queue.
private final class WrongHostKeyFlag: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: false)

    var isSet: Bool { value.withLock { $0 } }

    func set() {
        value.withLock { $0 = true }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
