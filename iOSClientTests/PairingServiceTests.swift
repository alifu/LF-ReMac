import Foundation
import Network
import RemoteCore
import Testing
@testable import iOSClient

private enum Keys {
    static func fingerprint(_ byte: UInt8) -> DeviceFingerprint {
        (try? DeviceFingerprint(bytes: Data(repeating: byte, count: DeviceFingerprint.byteCount)))
            ?? { preconditionFailure("fixture fingerprint") }()
    }

    static let host = fingerprint(0x11)
    static let other = fingerprint(0x33)
}

/// Real Keychain identity in a throw-away namespace; deleted afterwards.
private func withCredentials(
    isolation: isolated (any Actor)? = #isolation,
    _ body: (PhoneCredentials) async throws -> Void
) async throws {
    let namespace = "com.alifu.lfremac.tests.\(UUID().uuidString)"
    defer { try? DeviceIdentity.delete(namespace: namespace) }
    try await body(PhoneCredentials(namespace: namespace, keyStore: InMemoryKeyStore(), deviceName: "Test iPhone"))
}

@Suite(.serialized)
struct PhoneCredentialsTests {
    @Test func identityIsCreatedLazilyOnceAndReused() async throws {
        try await withCredentials { credentials in
            let first = try credentials.identity()
            let second = try credentials.identity()

            #expect(first === second)
            #expect(first.fingerprint != Keys.host)
        }
    }

    @Test func invalidDeviceNamesFallBack() {
        #expect(PhoneCredentials.validDeviceName("Ali's iPhone") == "Ali's iPhone")
        #expect(PhoneCredentials.validDeviceName("") == PhoneCredentials.fallbackDeviceName)
        #expect(PhoneCredentials.validDeviceName("evil\u{202E}name") == PhoneCredentials.fallbackDeviceName)
    }
}

@MainActor
@Suite(.serialized)
struct PairingServiceTests {
    private let secret = PairingSecret.random()

    private func invitation(fingerprint: DeviceFingerprint = Keys.host) throws -> PairingInvitation {
        try PairingInvitation(host: "mac.local", port: 47800, hostFingerprint: fingerprint, secret: secret)
    }

    nonisolated private static func result(_ fingerprint: DeviceFingerprint = Keys.host) -> PairingHandshakeResult {
        PairingHandshakeResult(hostName: "Mac mini", hostFingerprint: fingerprint, remoteHost: "10.0.0.2", remotePort: 47800)
    }

    @Test func qrFlowPinsTheInvitationKeyAndSavesTheHostAfterSuccess() async throws {
        try await withCredentials { credentials in
            let expectedHosts = ExpectationBox()
            let service = PairingService(credentials: credentials, handshake: { _, _, _, expected, name async throws(PairingHandshakeError) in
                expectedHosts.record(expected, name)
                return Self.result()
            })

            let host = try await service.pair(with: try invitation())

            #expect(expectedHosts.values == [ExpectationBox.Call(expected: Keys.host, deviceName: "Test iPhone")])
            #expect(host.fingerprint == Keys.host)
            #expect(host.lastKnownHost == "mac.local")
            #expect(credentials.hostStore.all() == [host])
        }
    }

    @Test func failedHandshakeStoresNothing() async throws {
        try await withCredentials { credentials in
            let service = PairingService(credentials: credentials, handshake: { _, _, _, _, _ async throws(PairingHandshakeError) in
                throw .invalidHostProof
            })

            await #expect(throws: PhonePairingError.invalidHostProof) { try await service.pair(with: try invitation()) }
            #expect(credentials.hostStore.all().isEmpty)
        }
    }

    @Test func resultForAnotherKeyThanTheInvitationIsRefused() async throws {
        try await withCredentials { credentials in
            let service = PairingService(credentials: credentials, handshake: { _, _, _, _, _ async throws(PairingHandshakeError) in
                Self.result(Keys.other)
            })

            await #expect(throws: PhonePairingError.hostFingerprintMismatch) { try await service.pair(with: try invitation()) }
            #expect(credentials.hostStore.all().isEmpty)
        }
    }

    @Test func manualFlowDoesNotPinAndStoresTheHandshakeKeyAndAddress() async throws {
        try await withCredentials { credentials in
            let calls = ExpectationBox()
            let service = PairingService(credentials: credentials, handshake: { _, _, _, expected, name async throws(PairingHandshakeError) in
                calls.record(expected, name)
                return Self.result()
            })

            let host = try await service.pair(endpoint: .hostPort(host: "10.0.0.2", port: 47800), name: "Studio Mac", code: secret)

            #expect(calls.values.first?.expected == nil)
            #expect(host.name == "Studio Mac")
            #expect(host.fingerprint == Keys.host)
            #expect(host.lastKnownHost == "10.0.0.2")
            #expect(host.lastKnownPort == 47800)
        }
    }

    @Test func handshakeErrorsMapToUserFacingErrors() {
        #expect(PhonePairingError(.rejected) == .codeRejected)
        #expect(PhonePairingError(.cannotReach) == .cannotReach)
        #expect(PhonePairingError(.timedOut) == .timedOut)
        #expect(!PhonePairingError.codeRejected.userMessage.isEmpty)
    }
}

/// Records what the fake handshake was called with.
private final class ExpectationBox: @unchecked Sendable {
    struct Call: Equatable {
        let expected: DeviceFingerprint?
        let deviceName: String
    }

    private let lock = NSLock()
    private var calls: [Call] = []

    var values: [Call] { lock.withLock { calls } }

    func record(_ expected: DeviceFingerprint?, _ deviceName: String) {
        lock.withLock { calls.append(Call(expected: expected, deviceName: deviceName)) }
    }
}

/// The proof logic the iPhone relies on, without a server.
struct PhonePairingProofTests {
    private let secret = PairingSecret.random()
    private let phone = Keys.fingerprint(0x22)

    @Test func requestCarriesAProofTheHostCanCheck() throws {
        let frame = try PairingExchange.requestFrame(secret: secret, clientFingerprint: phone, serverFingerprint: Keys.host, deviceName: "Phone")
        let request = try PairingMessageCoding.request(from: frame)

        #expect(PairingProof.isValidClientProof(request.proof, secret: secret, client: phone, server: Keys.host))
        #expect(!PairingProof.isValidClientProof(request.proof, secret: secret, client: phone, server: Keys.other))
    }

    @Test func hostProofOnlyVerifiesForTheHandshakeKeys() throws {
        let proof = PairingProof.host(secret: secret, client: phone, server: Keys.host)
        let frame = try PairingExchange.responseFrame(hostName: "Mac", hostProof: proof)

        #expect(throws: Never.self) {
            try PairingExchange.verifiedResponse(frame, secret: secret, clientFingerprint: phone, serverFingerprint: Keys.host)
        }
        #expect(throws: PairingResponseError.invalidHostProof) {
            try PairingExchange.verifiedResponse(frame, secret: secret, clientFingerprint: phone, serverFingerprint: Keys.other)
        }
        #expect(throws: PairingResponseError.invalidHostProof) {
            try PairingExchange.verifiedResponse(frame, secret: .random(), clientFingerprint: phone, serverFingerprint: Keys.host)
        }
    }
}
