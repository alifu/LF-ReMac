import Foundation
import RemoteCore
import Testing
@testable import MacHost

private enum Keys {
    static func fingerprint(_ byte: UInt8) -> DeviceFingerprint {
        (try? DeviceFingerprint(bytes: Data(repeating: byte, count: DeviceFingerprint.byteCount)))
            ?? { preconditionFailure("fixture fingerprint") }()
    }

    static let host = fingerprint(0x11)
    static let phone = fingerprint(0x22)
    static let other = fingerprint(0x33)
}

struct PairingCoordinatorTests {
    private let clock = TestClock()

    private func makeCoordinator(host: String = "mac.local") -> PairingCoordinator {
        PairingCoordinator(hostFingerprint: Keys.host, invitationHost: host, clock: clock.function)
    }

    @Test func startOpensAWindowAndDescribesItInTheInvitation() throws {
        let coordinator = makeCoordinator()

        let invitation = try coordinator.start(port: 47800)

        #expect(coordinator.isOpen)
        #expect(invitation.host == "mac.local")
        #expect(invitation.port == 47800)
        #expect(invitation.hostFingerprint == Keys.host)
        #expect(coordinator.displayCode == invitation.secret.displayCode)
        #expect(coordinator.expiresAt == clock.now.addingTimeInterval(PairingSession.lifetime))
    }

    @Test func invitationDescriptionNeverContainsTheSecret() throws {
        let invitation = try makeCoordinator().start(port: 1)

        #expect(!String(describing: invitation).contains(invitation.secret.compactCode))
    }

    @Test func closedByDefaultCancelAndExpiry() throws {
        let coordinator = makeCoordinator()
        #expect(!coordinator.isOpen)

        _ = try coordinator.start(port: 1)
        coordinator.cancel()
        #expect(!coordinator.isOpen)
        #expect(coordinator.displayCode == nil)

        _ = try coordinator.start(port: 1)
        clock.advance(by: PairingSession.lifetime)
        #expect(!coordinator.isOpen)
        #expect(coordinator.expiresAt == nil)
    }

    @Test func eachStartUsesAFreshSecret() throws {
        let coordinator = makeCoordinator()

        let first = try coordinator.start(port: 1)
        let second = try coordinator.start(port: 1)

        #expect(first.secret != second.secret)
    }

    @Test func invalidInvitationHostThrowsAndLeavesTheWindowClosed() {
        let coordinator = makeCoordinator(host: "")

        #expect(throws: PairingInvitationError.invalidHost) { try coordinator.start(port: 1) }
        #expect(!coordinator.isOpen)
    }

    @Test func correctProofPairsOnceAndClosesTheWindow() throws {
        let coordinator = makeCoordinator()
        let secret = try coordinator.start(port: 1).secret
        let proof = PairingProof.client(secret: secret, client: Keys.phone, server: Keys.host)

        let first = coordinator.attempt(proof: proof, clientFingerprint: Keys.phone, deviceName: "Phone")
        let replay = coordinator.attempt(proof: proof, clientFingerprint: Keys.phone, deviceName: "Phone")

        #expect(try first.get().device.fingerprint == Keys.phone)
        #expect(replay == .failure(.notActive))
        #expect(!coordinator.isOpen)
    }

    @Test func proofBoundToAnotherClientKeyIsRejected() throws {
        let coordinator = makeCoordinator()
        let secret = try coordinator.start(port: 1).secret
        let proof = PairingProof.client(secret: secret, client: Keys.other, server: Keys.host)

        #expect(coordinator.attempt(proof: proof, clientFingerprint: Keys.phone, deviceName: "Phone") == .failure(.invalidProof))
    }

    @Test func recordedFailuresUseUpTheAttemptBudget() throws {
        let coordinator = makeCoordinator()
        _ = try coordinator.start(port: 1)

        let failures = (0..<PairingSession.maxFailedAttempts).map { _ in coordinator.recordFailedAttempt(from: Keys.phone) }

        #expect(failures.allSatisfy { $0 == .invalidRequest })
        #expect(!coordinator.isOpen)
        #expect(coordinator.recordFailedAttempt(from: Keys.phone) == .tooManyAttempts)
    }
}

struct ConnectionAuthorizerTests {
    private func authorize(
        _ peer: DeviceFingerprint?, paired: Set<DeviceFingerprint> = [], open: Bool = false, pending: Int = 0
    ) -> ConnectionAuthorization {
        ConnectionAuthorizer.authorize(
            peer: peer, hostFingerprint: Keys.host, isPaired: { paired.contains($0) },
            isPairingOpen: open, pairingConnections: pending, maxPairingConnections: 2
        )
    }

    @Test func pairedPeerIsPairedEvenWhileTheWindowIsOpenOrFull() {
        #expect(authorize(Keys.phone, paired: [Keys.phone]) == .paired(Keys.phone))
        #expect(authorize(Keys.phone, paired: [Keys.phone], open: true, pending: 5) == .paired(Keys.phone))
    }

    @Test func unpairedPeerOnlyGetsAPairingRoleWhileTheWindowIsOpen() {
        #expect(authorize(Keys.phone) == .refused(.notPaired))
        #expect(authorize(Keys.phone, open: true) == .pairing(Keys.phone))
    }

    @Test func pairingConnectionsAreCapped() {
        #expect(authorize(Keys.phone, open: true, pending: 2) == .refused(.tooManyPairingConnections))
    }

    @Test func missingCertificateAndOwnKeyAreRefused() {
        #expect(authorize(nil, open: true) == .refused(.noPeerCertificate))
        #expect(authorize(Keys.host, paired: [Keys.host], open: true) == .refused(.ownFingerprint))
    }
}

struct PairingResponderTests {
    private let clock = TestClock()

    private func makeResponder(keyStore: any KeyStore = InMemoryKeyStore()) throws -> (PairingResponder, PairingSecret) {
        let coordinator = PairingCoordinator(hostFingerprint: Keys.host, invitationHost: "mac.local", clock: clock.function)
        let secret = try coordinator.start(port: 1).secret
        let store = PairedDeviceStore(keyStore: keyStore, key: "paired")
        return (PairingResponder(coordinator: coordinator, store: store, hostName: "Mac"), secret)
    }

    private func request(_ secret: PairingSecret, name: String = "Phone") throws -> Frame {
        try PairingExchange.requestFrame(secret: secret, clientFingerprint: Keys.phone, serverFingerprint: Keys.host, deviceName: name)
    }

    @Test func validRequestSavesTheDeviceAndAnswersWithAVerifiableHostProof() throws {
        let (responder, secret) = try makeResponder()

        guard case .accepted(let device, let response) = responder.respond(to: try request(secret), from: Keys.phone) else {
            Issue.record("expected acceptance")
            return
        }

        #expect(device.name == "Phone")
        #expect(responder.store.contains(Keys.phone))
        let verified = try PairingExchange.verifiedResponse(response, secret: secret, clientFingerprint: Keys.phone, serverFingerprint: Keys.host)
        #expect(verified.hostName == "Mac")
    }

    @Test func expiredWindowRejectsAndSavesNothing() throws {
        let (responder, secret) = try makeResponder()
        clock.advance(by: PairingSession.lifetime + 1)

        #expect(responder.respond(to: try request(secret), from: Keys.phone) == .rejected(.attempt(.expired)))
        #expect(responder.store.all().isEmpty)
    }

    @Test func malformedRequestCountsAsAFailedAttempt() throws {
        let (responder, _) = try makeResponder()
        let garbage = Frame(type: .pairRequest, timestampMicros: 0, payload: Data("{}".utf8))

        #expect(responder.respond(to: garbage, from: Keys.phone) == .rejected(.attempt(.invalidRequest)))
        #expect(responder.protocolViolation(from: Keys.phone) == .attempt(.invalidRequest))
        #expect(responder.protocolViolation(from: Keys.phone) == .attempt(.invalidRequest))
        #expect(!responder.coordinator.isOpen)
    }

    @Test func storeFailureIsReportedAndNoReplyIsSent() throws {
        let (responder, secret) = try makeResponder(keyStore: FailingKeyStore())

        #expect(responder.respond(to: try request(secret), from: Keys.phone) == .rejected(.couldNotSave))
    }
}

private struct FailingKeyStore: KeyStore {
    func data(forKey key: String) throws(KeyStoreError) -> Data? { nil }
    func set(_ data: Data, forKey key: String) throws(KeyStoreError) { throw .keychain(-1) }
    func removeData(forKey key: String) throws(KeyStoreError) { throw .keychain(-1) }
}
