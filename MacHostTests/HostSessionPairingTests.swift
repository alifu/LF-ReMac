import Foundation
import Network
import RemoteCore
import Testing
@testable import MacHost

/// `HostSession`'s pairing API with an injected identity, in-memory store and loopback server.
/// No phone connects in pinned mode, so screen capture never starts.
@MainActor
@Suite(.serialized)
struct HostSessionPairingTests {
    private func withSession(
        keyStore: InMemoryKeyStore = InMemoryKeyStore(),
        _ body: (HostSession, DeviceIdentity, UInt16) async throws -> Void
    ) async throws {
        try await TestIdentity.withIdentities(["Session Mac", "Session Phone"]) { identities in
            let host = identities[0]
            let environment = HostEnvironment(
                loadIdentity: { _ in host }, keyStore: keyStore, displayName: { "Session Mac" },
                invitationHost: { "127.0.0.1" }, serviceType: nil, port: .any, clock: { Date() },
                limits: ServerHarness.shortLimits
            )
            let session = HostSession(environment: environment)
            session.start()
            try await eventually { if case .listening = session.state { true } else { false } }
            guard case .listening(let port) = session.state else { throw LoopbackError.serverNeverReady }
            try await body(session, identities[1], port)
            await session.stop()
        }
    }

    @Test func startPairingIsUnavailableBeforeHosting() {
        #expect(HostSession(environment: .live).startPairing() == nil)
    }

    @Test func failedIdentityLoadFailsTheSessionClearly() {
        let environment = HostEnvironment(
            loadIdentity: { _ in throw IdentityError.identityNotFound }, keyStore: InMemoryKeyStore(),
            displayName: { "Mac" }, invitationHost: { nil }, serviceType: nil, port: .any, clock: { Date() },
            limits: .standard
        )
        let session = HostSession(environment: environment)

        session.start()

        guard case .failed(let message) = session.state else {
            Issue.record("expected failure")
            return
        }
        #expect(message.contains("identity"))
    }

    @Test func pairingThroughTheSessionAddsTheDeviceAndClosesTheWindow() async throws {
        try await withSession { session, phone, port in
            let invitation = try #require(session.startPairing())
            guard case .open(let shown, _) = session.pairingState else {
                Issue.record("window not open")
                return
            }
            #expect(shown == invitation)
            #expect(invitation.port == port)

            _ = try await PairingHandshake.run(
                endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any),
                identity: phone, secret: invitation.secret, expectedHostFingerprint: invitation.hostFingerprint,
                deviceName: "Session Phone"
            )

            try await eventually { session.pairingState == .paired(deviceName: "Session Phone") }
            #expect(session.pairedDevices.map(\.fingerprint) == [phone.fingerprint])
        }
    }

    @Test func cancelledWindowRefusesPairing() async throws {
        try await withSession { session, phone, port in
            let invitation = try #require(session.startPairing())
            session.cancelPairing()
            #expect(session.pairingState == .idle)

            await #expect(throws: PairingHandshakeError.rejected) {
                try await PairingHandshake.run(
                    endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any),
                    identity: phone, secret: invitation.secret, expectedHostFingerprint: invitation.hostFingerprint,
                    deviceName: "Session Phone"
                )
            }
            #expect(session.pairedDevices.isEmpty)
        }
    }

    @Test func revokeRemovesTheDevice() async throws {
        try await withSession { session, phone, port in
            let invitation = try #require(session.startPairing())
            _ = try await PairingHandshake.run(
                endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any),
                identity: phone, secret: invitation.secret, expectedHostFingerprint: invitation.hostFingerprint,
                deviceName: "Session Phone"
            )
            try await eventually { !session.pairedDevices.isEmpty }

            try session.revoke(session.pairedDevices[0])

            #expect(session.pairedDevices.isEmpty)
        }
    }

    @Test func damagedPairedListIsReportedAndCanBeResetExplicitly() async throws {
        let keyStore = InMemoryKeyStore([HostEnvironment.pairedDevicesKey: Data("garbage".utf8)])
        try await withSession(keyStore: keyStore) { session, _, _ in
            #expect(session.pairedDevicesIssue?.contains("damaged") == true)
            #expect(session.pairedDevices.isEmpty)

            try session.resetPairedDevices()

            #expect(session.pairedDevicesIssue == nil)
            #expect(try keyStore.data(forKey: HostEnvironment.pairedDevicesKey) == nil)
        }
    }

    @Test func healthyPairedListHasNoIssue() async throws {
        try await withSession { session, _, _ in
            #expect(session.pairedDevicesIssue == nil)
        }
    }
}

@MainActor
struct HostSessionSettingsTests {
    private final class Counter: @unchecked Sendable { var held = 0 }

    @Test func keepAwakeAndTailscaleDefaultToOnAndOff() {
        let session = HostSession(environment: HostEnvironment(
            loadIdentity: { _ in throw IdentityError.identityNotFound }, keyStore: InMemoryKeyStore(),
            displayName: { "Mac" }, invitationHost: { nil }, serviceType: nil, port: .any, clock: { Date() },
            limits: .standard
        ))

        #expect(session.keepsMacAwake)
        #expect(!session.allowsTailscale)
    }

    @Test func choicesAreRemembered() {
        let settings = MemorySettings()
        func make() -> HostSession {
            HostSession(environment: HostEnvironment(
                loadIdentity: { _ in throw IdentityError.identityNotFound }, keyStore: InMemoryKeyStore(),
                displayName: { "Mac" }, invitationHost: { nil }, serviceType: nil, port: .any, clock: { Date() },
                limits: .standard, settings: settings
            ))
        }
        let first = make()
        first.setKeepsMacAwake(false)
        first.setAllowsTailscale(true)

        let second = make()

        #expect(!second.keepsMacAwake)
        #expect(second.allowsTailscale)
    }
}
