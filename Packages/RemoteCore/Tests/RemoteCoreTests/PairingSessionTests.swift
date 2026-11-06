import Foundation
import Testing
@testable import RemoteCore

struct PairingSessionTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let secret = Fixtures.secret()

    private var validProof: Data {
        PairingProof.client(secret: secret, client: Fixtures.phone, server: Fixtures.host)
    }

    private func attempt(
        _ session: PairingSession, proof: Data? = nil, client: DeviceFingerprint = Fixtures.phone,
        name: String = "iPhone", after seconds: TimeInterval = 10
    ) -> PairingAttemptOutcome {
        session.attempt(
            proof: proof ?? validProof, clientFingerprint: client, serverFingerprint: Fixtures.host,
            deviceName: name, now: start.addingTimeInterval(seconds)
        )
    }

    private var open: PairingSession { PairingSession.start(now: start, secret: secret) }
    private var wrongProof: Data { Data(repeating: 0, count: 32) }

    @Test func validProofPairsTheDeviceAndReturnsTheHostProof() throws {
        let outcome = attempt(open)

        let acceptance = try outcome.result.get()
        #expect(acceptance.device == PairedDevice(name: "iPhone", fingerprint: Fixtures.phone, pairedAt: start.addingTimeInterval(10)))
        #expect(PairingProof.isValidHostProof(acceptance.hostProof, secret: secret, client: Fixtures.phone, server: Fixtures.host))
    }

    @Test func secretIsSingleUse() {
        let first = attempt(open)

        let second = attempt(first.session)

        #expect(second.result == .failure(.notActive))
        #expect(first.session.secret(now: start) == nil)
    }

    @Test func expiresAfterTwoMinutes() {
        #expect(PairingSession.lifetime == 120)
        #expect(open.secret(now: start.addingTimeInterval(119.9)) == secret)
        #expect(open.secret(now: start.addingTimeInterval(120)) == nil)

        let outcome = attempt(open, after: 120)

        #expect(outcome.result == .failure(.expired))
        #expect(attempt(outcome.session, after: 1).result == .failure(.expired))
    }

    @Test func threeFailuresInvalidateTheSessionEvenForTheCorrectProof() {
        let first = attempt(open, proof: wrongProof)
        let second = attempt(first.session, proof: wrongProof)
        let third = attempt(second.session, proof: wrongProof)

        let afterwards = attempt(third.session)

        #expect([first, second, third].map(\.result) == Array(repeating: .failure(.invalidProof), count: 3))
        #expect(afterwards.result == .failure(.tooManyAttempts))
        #expect(!third.session.isOpen(now: start))
    }

    @Test func twoFailuresStillAllowTheCorrectProof() throws {
        let first = attempt(open, proof: wrongProof)
        let second = attempt(first.session, proof: wrongProof)

        #expect(throws: Never.self) { try attempt(second.session).result.get() }
    }

    @Test func cancelClosesTheWindow() {
        let cancelled = open.cancelled()

        #expect(attempt(cancelled).result == .failure(.notActive))
        #expect(cancelled.secret(now: start) == nil)
    }

    @Test func neverStartedSessionRejects() {
        #expect(attempt(PairingSession()).result == .failure(.notActive))
    }

    @Test func proofForAnotherClientKeyIsRejected() {
        // A MITM presenting its own TLS key to the host cannot reuse the phone's proof.
        #expect(attempt(open, client: Fixtures.attacker).result == .failure(.invalidProof))
    }

    @Test func invalidNameOrReflectedFingerprintCountsAsFailure() {
        let badName = attempt(open, name: "bad\nname")
        let reflected = attempt(badName.session, client: Fixtures.host)
        let third = attempt(reflected.session, proof: wrongProof)

        #expect(badName.result == .failure(.invalidRequest))
        #expect(reflected.result == .failure(.invalidRequest))
        #expect(attempt(third.session).result == .failure(.tooManyAttempts))
    }

    @Test func originalValueIsUnchangedByAttempts() {
        let session = open
        _ = attempt(session, proof: wrongProof)

        #expect(session.state == .active(secret: secret, expiresAt: start.addingTimeInterval(120), failedAttempts: 0))
    }

    @Test func failureErrorsRevealNothingAboutTheProof() {
        let almostRight = Data(validProof.dropLast()) + Data([validProof.last.map { $0 ^ 1 } ?? 0])

        #expect(attempt(open, proof: almostRight).result == attempt(open, proof: wrongProof).result)
    }
}
