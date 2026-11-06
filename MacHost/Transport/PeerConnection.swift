import Foundation
import Network
import RemoteCore

/// Per-connection state; only touched on the server queue.
final class PeerConnection: @unchecked Sendable {
    enum Role: Equatable {
        /// TLS not finished; nothing is read from the peer yet.
        case handshaking
        /// The active, authorized session.
        case paired(DeviceFingerprint)
        /// Unpaired peer during an open pairing window; reads with a tiny, pairRequest-only decoder.
        case pairing(DeviceFingerprint)
        /// Pairing reply sent; waiting for the peer to close. Any further data is ignored.
        case finished
    }

    static let pairedReadBytes = 64 * 1024

    let connection: NWConnection
    /// Where the connection comes from, for per-address quotas.
    let source: ConnectionSource
    private(set) var role: Role = .handshaking
    private(set) var decoder = FrameDecoder()
    var gate = ClientSendGate()
    /// Set by `cancel()`; the `.cancelled` state update arrives later, so callers check this first.
    private(set) var isClosed = false
    private var deadline: DispatchWorkItem?

    init(connection: NWConnection) {
        self.connection = connection
        self.source = ConnectionSource(endpoint: connection.endpoint)
    }

    var fingerprint: DeviceFingerprint? {
        switch role {
        case .paired(let fingerprint), .pairing(let fingerprint): fingerprint
        case .handshaking, .finished: nil
        }
    }

    var isPairing: Bool {
        if case .pairing = role { return true }
        return false
    }

    var readBytes: Int {
        if case .paired = role { return Self.pairedReadBytes }
        return PairingExchange.maxReadBytes
    }

    func becomePaired(_ fingerprint: DeviceFingerprint) {
        role = .paired(fingerprint)
        decoder = FrameDecoder()
        clearDeadline()
    }

    func becomePairing(_ fingerprint: DeviceFingerprint) {
        role = .pairing(fingerprint)
        decoder = PairingExchange.requestDecoder()
    }

    func finishPairing() {
        role = .finished
    }

    func decode(_ data: Data) throws(FrameError) -> [Frame] {
        try decoder.append(data)
    }

    /// Cancels the connection after `interval` unless replaced by another deadline or cleared.
    /// `onExpire` runs on `queue` just before the cancellation.
    func setDeadline(after interval: TimeInterval, on queue: DispatchQueue, onExpire: @escaping @Sendable () -> Void = {}) {
        clearDeadline()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !isClosed else { return }
            onExpire()
            cancel()
        }
        deadline = item
        queue.asyncAfter(deadline: .now() + interval, execute: item)
    }

    func clearDeadline() {
        deadline?.cancel()
        deadline = nil
    }

    func cancel() {
        isClosed = true
        clearDeadline()
        connection.cancel()
    }
}
