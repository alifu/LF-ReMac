import Foundation
import Network
import RemoteCore
import Testing
@testable import iOSClient

@MainActor
struct PairingModelTests {
    private func makeModel(pairedHosts: [PairedHost] = []) throws -> PairingModel {
        let credentials = PhoneCredentials(
            namespace: "com.alifu.lfremac.tests.\(UUID().uuidString)",
            keyStore: InMemoryKeyStore(),
            deviceName: "Test Phone"
        )
        // Handshake must never be reached by the input-validation tests below.
        let service = PairingService(credentials: credentials, handshake: { _, _, _, _, _ async throws(PairingHandshakeError) in
            throw PairingHandshakeError.cannotReach
        })
        return PairingModel(service: service, pairedHosts: { pairedHosts })
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

    // MARK: QR confirmation (security review M1)

    private func invitation(host: String = "mac.local", byte: UInt8 = 7) throws -> PairingInvitation {
        try PairingInvitation(
            host: host, port: 47800,
            hostFingerprint: try DeviceFingerprint(bytes: Data(repeating: byte, count: 32)),
            secret: try PairingSecret.random()
        )
    }

    @Test func scanningAValidCodeAsksForConfirmationInsteadOfConnecting() async throws {
        let model = try makeModel()
        let invitation = try invitation()

        await model.handleScanned(invitation.urlString)

        #expect(model.state == .confirming(PairingConfirmation(
            hostLabel: "mac.local",
            securityCode: invitation.hostFingerprint.verificationCode,
            warning: nil
        )))
    }

    @Test func confirmingRunsThePairing() async throws {
        let model = try makeModel()
        await model.handleScanned(try invitation().urlString)

        await model.confirmScanned()

        #expect(model.state == .failed(PhonePairingError.cannotReach.userMessage))
    }

    @Test func decliningReturnsToIdleWithoutConnecting() async throws {
        let model = try makeModel()
        await model.handleScanned(try invitation().urlString)

        model.cancelConfirmation()

        #expect(model.state == .idle)
    }

    @Test func confirmWithoutAScanDoesNothing() async throws {
        let model = try makeModel()

        await model.confirmScanned()

        #expect(model.state == .idle)
    }

    @Test func aSecondScanWhileConfirmingIsIgnored() async throws {
        let model = try makeModel()
        let first = try invitation(host: "first.local", byte: 1)
        await model.handleScanned(first.urlString)

        await model.handleScanned(try invitation(host: "second.local", byte: 2).urlString)

        guard case .confirming(let confirmation) = model.state else {
            Issue.record("expected the first confirmation to stay")
            return
        }
        #expect(confirmation.hostLabel == "first.local")
    }

    @Test func warnsWhenTheSameMacIsAlreadyPaired() throws {
        let invitation = try invitation()
        let existing = PairedHost(
            name: "Mac", fingerprint: invitation.hostFingerprint, pairedAt: Date(),
            lastKnownHost: nil, lastKnownPort: nil
        )

        let confirmation = PairingModel.confirmation(for: invitation, existing: [existing])

        #expect(confirmation.warning?.contains("already paired") == true)
    }

    @Test func warnsStronglyWhenANameMatchesButTheKeyDiffers() throws {
        let invitation = try invitation(host: "Alifs-Mac-mini.local", byte: 9)
        let existing = PairedHost(
            name: "alifs-mac-mini", fingerprint: try DeviceFingerprint(bytes: Data(repeating: 1, count: 32)),
            pairedAt: Date(), lastKnownHost: nil, lastKnownPort: nil
        )

        let confirmation = PairingModel.confirmation(for: invitation, existing: [existing])

        #expect(confirmation.warning?.contains("DIFFERENT") == true)
    }

    @Test func noWarningForAnUnrelatedMac() throws {
        let existing = PairedHost(
            name: "Office Mac", fingerprint: try DeviceFingerprint(bytes: Data(repeating: 1, count: 32)),
            pairedAt: Date(), lastKnownHost: "office.local", lastKnownPort: 47800
        )

        let confirmation = PairingModel.confirmation(for: try invitation(host: "home.local", byte: 3), existing: [existing])

        #expect(confirmation.warning == nil)
    }
}
