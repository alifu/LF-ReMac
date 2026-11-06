import Foundation
import os
import RemoteCore

/// Owns the host's single `PairingSession` behind one lock, so the TLS verify block ("is a pairing
/// window open?"), the server queue (attempts) and the UI (start/cancel/display) share one state.
///
/// The secret leaves this type only inside the `PairingInvitation` returned by `start` (for the QR
/// code) and through `displayCode` (for the window); both types redact it from descriptions.
final class PairingCoordinator: Sendable {
    typealias Clock = @Sendable () -> Date

    let hostFingerprint: DeviceFingerprint
    private let invitationHost: String
    private let clock: Clock
    private let session = OSAllocatedUnfairLock(initialState: PairingSession())

    /// - Parameters:
    ///   - invitationHost: name or IP literal the iPhone should dial (goes into the QR code).
    ///   - clock: injectable for expiry tests.
    init(hostFingerprint: DeviceFingerprint, invitationHost: String, clock: @escaping Clock = { Date() }) {
        self.hostFingerprint = hostFingerprint
        self.invitationHost = invitationHost
        self.clock = clock
    }

    /// Opens a fresh window with a new random secret, replacing any previous one.
    func start(port: UInt16) throws(PairingInvitationError) -> PairingInvitation {
        let secret = PairingSecret.random()
        let invitation = try PairingInvitation(
            host: invitationHost, port: port, hostFingerprint: hostFingerprint, secret: secret
        )
        let now = clock()
        session.withLock { $0 = PairingSession.start(now: now, secret: secret) }
        return invitation
    }

    func cancel() {
        session.withLock { $0 = $0.cancelled() }
    }

    /// True while a secret is usable (started, not expired, not used, not exhausted).
    var isOpen: Bool {
        let now = clock()
        return session.withLock { $0.isOpen(now: now) }
    }

    /// When the open window closes; nil when no window is open.
    var expiresAt: Date? {
        let now = clock()
        return session.withLock { $0.isOpen(now: now) ? $0.expiresAt : nil }
    }

    /// `XXXX-XXXX-XXXX-XXXX` for the pairing window only; nil when no window is open.
    var displayCode: String? {
        let now = clock()
        return session.withLock { $0.secret(now: now)?.displayCode }
    }

    /// Checks a request against the window. `clientFingerprint` must come from the TLS handshake.
    func attempt(proof: Data, clientFingerprint: DeviceFingerprint, deviceName: String) -> Result<PairingAcceptance, PairingFailure> {
        let now = clock()
        return session.withLock { current in
            let outcome = current.attempt(
                proof: proof, clientFingerprint: clientFingerprint, serverFingerprint: hostFingerprint,
                deviceName: deviceName, now: now
            )
            current = outcome.session
            return outcome.result
        }
    }

    /// Counts unusable pairing traffic from an unpaired peer (malformed request, wrong frame type,
    /// oversized frame) as a failed attempt, so it uses up the same 3-attempt budget.
    func recordFailedAttempt(from clientFingerprint: DeviceFingerprint) -> PairingFailure {
        // An empty name and proof always fail with `.invalidRequest` (or the window's own state).
        let result = attempt(proof: Data(), clientFingerprint: clientFingerprint, deviceName: "")
        guard case .failure(let failure) = result else { return .invalidRequest }
        return failure
    }
}
