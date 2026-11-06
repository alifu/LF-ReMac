import Foundation

/// Why a pairing attempt was refused. Deliberately coarse: nothing says how close a proof was.
public enum PairingFailure: Error, Equatable, Sendable {
    /// No pairing window open (never started, cancelled, or the secret was already used).
    case notActive
    case expired
    /// The session was invalidated after `PairingSession.maxFailedAttempts` failures.
    case tooManyAttempts
    case invalidProof
    /// Malformed request (bad name, client fingerprint equals the host's). Does NOT use up an
    /// attempt: only a well-formed request with a wrong proof does, so junk cannot close the window.
    case invalidRequest
}

/// What the host gets from a successful attempt: the device to persist and the proof to send back.
public struct PairingAcceptance: Equatable, Sendable {
    public let device: PairedDevice
    /// `PairingProof.host(...)` for the `PairResponse`.
    public let hostProof: Data
}

public struct PairingAttemptOutcome: Sendable {
    /// The session to keep using from now on (the old value must be discarded).
    public let session: PairingSession
    public let result: Result<PairingAcceptance, PairingFailure>
}

/// Host-side pairing window state. A value type: every operation returns the next session, so the
/// owner (one serial context, e.g. the server queue or an actor) simply replaces its copy.
///
/// Rules (plan, Phase 4): one random secret per window, valid for `lifetime` (2 minutes), single use,
/// invalidated after `maxFailedAttempts` (3) wrong proofs, closed by `cancelled()`.
public struct PairingSession: Sendable {
    public static let lifetime: TimeInterval = 120
    public static let maxFailedAttempts = 3

    enum State: Sendable, Equatable {
        case inactive
        case active(secret: PairingSecret, expiresAt: Date, failedAttempts: Int)
        case expired
        case exhausted
    }

    let state: State

    /// A closed session; nothing can pair until `start`.
    public init() {
        state = .inactive
    }

    init(state: State) {
        self.state = state
    }

    public static func start(now: Date, secret: PairingSecret = .random(), lifetime: TimeInterval = lifetime) -> PairingSession {
        PairingSession(state: .active(secret: secret, expiresAt: now.addingTimeInterval(lifetime), failedAttempts: 0))
    }

    /// The secret to display (code + QR) while the window is usable; nil otherwise.
    public func secret(now: Date) -> PairingSecret? {
        guard case .active(let secret, let expiresAt, _) = state, now < expiresAt else { return nil }
        return secret
    }

    public var expiresAt: Date? {
        guard case .active(_, let expiresAt, _) = state else { return nil }
        return expiresAt
    }

    public func isOpen(now: Date) -> Bool {
        secret(now: now) != nil
    }

    public func cancelled() -> PairingSession {
        PairingSession()
    }

    /// Checks a `PairRequest` against this window, using the fingerprints *the host observed* in
    /// the TLS handshake (never values supplied by the peer).
    public func attempt(
        proof: Data,
        clientFingerprint: DeviceFingerprint,
        serverFingerprint: DeviceFingerprint,
        deviceName: String,
        now: Date
    ) -> PairingAttemptOutcome {
        switch state {
        case .inactive: return outcome(self, .failure(.notActive))
        case .expired: return outcome(self, .failure(.expired))
        case .exhausted: return outcome(self, .failure(.tooManyAttempts))
        case .active(let secret, let expiresAt, let failures):
            guard now < expiresAt else { return outcome(PairingSession(state: .expired), .failure(.expired)) }
            let window = ActiveWindow(secret: secret, expiresAt: expiresAt, failedAttempts: failures)
            return window.check(
                proof: proof, client: clientFingerprint, server: serverFingerprint, deviceName: deviceName, now: now
            )
        }
    }

    private func outcome(_ session: PairingSession, _ result: Result<PairingAcceptance, PairingFailure>) -> PairingAttemptOutcome {
        PairingAttemptOutcome(session: session, result: result)
    }
}

/// The checks for an open, unexpired window.
private struct ActiveWindow {
    let secret: PairingSecret
    let expiresAt: Date
    let failedAttempts: Int

    func check(
        proof: Data, client: DeviceFingerprint, server: DeviceFingerprint, deviceName: String, now: Date
    ) -> PairingAttemptOutcome {
        guard DeviceName.isValid(deviceName), !client.constantTimeEquals(server) else {
            return PairingAttemptOutcome(session: unchanged, result: .failure(.invalidRequest))
        }
        guard PairingProof.isValidClientProof(proof, secret: secret, client: client, server: server) else {
            return failed(.invalidProof)
        }
        let acceptance = PairingAcceptance(
            device: PairedDevice(name: deviceName, fingerprint: client, pairedAt: now),
            hostProof: PairingProof.host(secret: secret, client: client, server: server)
        )
        // Single use: the secret is gone as soon as it has paired one device.
        return PairingAttemptOutcome(session: PairingSession(), result: .success(acceptance))
    }

    private var unchanged: PairingSession {
        PairingSession(state: .active(secret: secret, expiresAt: expiresAt, failedAttempts: failedAttempts))
    }

    private func failed(_ failure: PairingFailure) -> PairingAttemptOutcome {
        let failures = failedAttempts + 1
        let next: PairingSession.State = failures >= PairingSession.maxFailedAttempts
            ? .exhausted
            : .active(secret: secret, expiresAt: expiresAt, failedAttempts: failures)
        return PairingAttemptOutcome(session: PairingSession(state: next), result: .failure(failure))
    }
}
