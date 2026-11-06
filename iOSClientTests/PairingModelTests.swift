import Foundation
import Network
import RemoteCore
import Testing
@testable import iOSClient

@MainActor
struct PairingModelTests {
    private func makeModel() throws -> PairingModel {
        let credentials = PhoneCredentials(
            namespace: "com.alifu.lfremac.tests.\(UUID().uuidString)",
            keyStore: InMemoryKeyStore(),
            deviceName: "Test Phone"
        )
        // Handshake must never be reached by the input-validation tests below.
        let service = PairingService(credentials: credentials, handshake: { _, _, _, _, _ async throws(PairingHandshakeError) in
            throw PairingHandshakeError.cannotReach
        })
        return PairingModel(service: service)
    }

    @Test func startsIdle() throws {
        #expect(try makeModel().state == .idle)
    }

    @Test func scanningSomethingThatIsNotAPairingCodeFailsWithoutConnecting() async throws {
        let model = try makeModel()

        await model.handleScanned("https://example.com/hello")

        #expect(model.state == .failed(PairingInputError.notAnInvitation.userMessage))
    }

    @Test func typingAnInvalidCodeFailsWithoutConnecting() async throws {
        let model = try makeModel()
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 47800)

        await model.pair(endpoint: endpoint, name: "Mac", codeText: "not a code!")

        #expect(model.state == .failed(PairingInputError.invalidCode.userMessage))
    }

    @Test func aValidCodeReachesTheServiceAndReportsItsError() async throws {
        let model = try makeModel()
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 47800)
        let code = try PairingSecret.random().displayCode

        await model.pair(endpoint: endpoint, name: "Mac", codeText: code)

        #expect(model.state == .failed(PhonePairingError.cannotReach.userMessage))
    }

    @Test func resetReturnsToIdleAfterAFailure() async throws {
        let model = try makeModel()
        await model.handleScanned("garbage")

        model.reset()

        #expect(model.state == .idle)
    }

    @Test func parsesAValidInvitationUrl() throws {
        let invitation = try PairingInvitation(
            host: "mac.local", port: 47800,
            hostFingerprint: try DeviceFingerprint(bytes: Data(repeating: 7, count: 32)),
            secret: try PairingSecret.random()
        )

        let parsed = try PairingModel.invitation(from: invitation.urlString).get()

        #expect(parsed.host == "mac.local")
        #expect(parsed.port == 47800)
    }
}
