import Foundation
import Network
import os
import RemoteCore
import Testing
@testable import MacHost

/// Per-address quotas and attempt accounting over real loopback sockets. 127.0.0.1 plays the
/// attacker and ::1 the paired iPhone, so the two count as different remote addresses.
@Suite(.serialized)
struct ConnectionQuotaLoopbackTests {
    private static func isClientConnected(_ event: StreamServerEvent) -> Bool {
        if case .clientConnected = event { return true }
        return false
    }

    @Test func idleConnectionsFromOneAddressCannotLockOutThePairedIPhone() async throws {
        let limits = ServerHarness.limits(maxHandshaking: 8, perAddressHandshaking: 2, handshakeTimeout: 5)
        try await ServerHarness.run(phones: ["Owner"], limits: limits) { harness, phones in
            try harness.pair(phones[0])
            // The attacker fills its own quota with TCP connections that never start TLS.
            let idle = (0..<4).map { _ in IdleTCPConnection(address: "127.0.0.1", port: harness.port) }
            defer { idle.forEach { $0.cancel() } }
            try await Task.sleep(for: .milliseconds(300))

            let sameAddress = try harness.connect(phones[0], address: "127.0.0.1")
            defer { sameAddress.close() }
            try await sameAddress.waitUntilClosed()

            let owner = try harness.connect(phones[0], address: "::1")
            defer { owner.close() }
            try await harness.recorder.waitFor(.clientConnected(phones[0].fingerprint))
            #expect(!owner.isClosed)
        }
    }

    @Test func handshakeTimeoutFreesTheSlot() async throws {
        let limits = ServerHarness.limits(perAddressHandshaking: 1, handshakeTimeout: 0.3)
        try await ServerHarness.run(phones: ["Owner"], limits: limits) { harness, phones in
            try harness.pair(phones[0])
            let idle = IdleTCPConnection(address: "127.0.0.1", port: harness.port)
            defer { idle.cancel() }
            try await Task.sleep(for: .milliseconds(600))

            let owner = try harness.connect(phones[0])
            defer { owner.close() }

            try await harness.recorder.waitFor(.clientConnected(phones[0].fingerprint))
        }
    }

    @Test func oneAddressHoldsAtMostOnePairingConnection() async throws {
        let limits = ServerHarness.limits(maxPairing: 4, perAddressPairing: 1)
        try await ServerHarness.run(phones: ["Squatter", "Second", "Real Phone"], limits: limits) { harness, phones in
            let invitation = try harness.coordinator.start(port: harness.port)
            let squatter = try harness.connect(phones[0])
            defer { squatter.close() }
            try await squatter.waitUntilReady()
            try await Task.sleep(for: .milliseconds(200))

            let second = try harness.connect(phones[1])
            defer { second.close() }
            try await second.waitUntilClosed()

            let result = try await PairingHandshake.run(
                endpoint: .hostPort(host: "::1", port: NWEndpoint.Port(rawValue: harness.port) ?? .any),
                identity: phones[2], secret: invitation.secret, expectedHostFingerprint: invitation.hostFingerprint,
                deviceName: "Real Phone", timeout: .seconds(5)
            )
            #expect(result.hostFingerprint == harness.host.fingerprint)
            #expect(!squatter.isClosed)
        }
    }

    @Test func junkAndTimeoutsDoNotUseUpAttemptsButWrongCodesDo() async throws {
        try await ServerHarness.run(phones: ["Noisy", "Owner"]) { harness, phones in
            let invitation = try harness.coordinator.start(port: harness.port)
            for _ in 0..<PairingSession.maxFailedAttempts + 1 {
                let junk = try harness.connect(phones[0])
                defer { junk.close() }
                try await junk.waitUntilReady()
                junk.send(try InputEventCoding.frame(for: .text("x"), timestampMicros: 0))
                try await junk.waitUntilClosed()
            }
            let silent = try harness.connect(phones[0])
            defer { silent.close() }
            try await silent.waitUntilClosed()
            try await harness.recorder.waitFor(.pairingFailed(.malformedRequest), count: PairingSession.maxFailedAttempts + 1)
            try await harness.recorder.waitFor(.pairingFailed(.timedOut))
            #expect(harness.coordinator.isOpen)

            await #expect(throws: PairingHandshakeError.rejected) {
                try await harness.runPairing(phones[0], secret: .random(), expected: nil)
            }
            try await harness.recorder.waitFor(.pairingFailed(.attempt(.invalidProof)))

            _ = try await harness.runPairing(phones[1], secret: invitation.secret, expected: invitation.hostFingerprint)
            #expect(harness.store.contains(phones[1].fingerprint))
        }
    }
}

/// A plain TCP connection that never speaks TLS (an attacker parking a handshake slot).
private final class IdleTCPConnection: Sendable {
    private let connection: NWConnection

    init(address: String, port: UInt16) {
        connection = NWConnection(
            host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: port) ?? .any, using: .tcp
        )
        connection.start(queue: DispatchQueue(label: "loopback.idle-tcp"))
    }

    func cancel() {
        connection.cancel()
    }
}
