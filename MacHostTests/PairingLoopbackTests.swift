import Foundation
import RemoteCore
import Testing
@testable import MacHost

/// End to end over loopback: real sockets, real mutual TLS 1.3, the real `StreamServer` and the
/// iPhone's real `PairingHandshake`.
@Suite(.serialized)
struct PairingLoopbackTests {
    private static func isPairingFailure(_ event: StreamServerEvent) -> Bool {
        if case .pairingFailed = event { return true }
        return false
    }

    private static func isClientConnected(_ event: StreamServerEvent) -> Bool {
        if case .clientConnected = event { return true }
        return false
    }

    // (a)
    @Test func pairingWithTheSecretSucceedsAndThePhoneThenStreamsInPinnedMode() async throws {
        try await ServerHarness.run(phones: ["New Phone"]) { harness, phones in
            let phone = phones[0]
            let invitation = try harness.coordinator.start(port: harness.port)

            let result = try await harness.runPairing(phone, secret: invitation.secret, expected: invitation.hostFingerprint)

            #expect(result.hostFingerprint == harness.host.fingerprint)
            #expect(result.hostName == "Test Mac")
            #expect(harness.store.contains(phone.fingerprint))
            #expect(!harness.coordinator.isOpen)
            try await harness.recorder.waitFor { if case .devicePaired(let device) = $0 { device.fingerprint == phone.fingerprint } else { false } }

            let client = try harness.connect(phone)
            defer { client.close() }
            try await harness.recorder.waitFor(.clientConnected(phone.fingerprint))
            let config = Frame(type: .videoConfig, timestampMicros: 0, payload: Data([1]))
            let key = Frame(type: .videoFrame, flags: [.keyframe], timestampMicros: 1, payload: Data([2]))
            harness.server.broadcast(config)
            harness.server.broadcast(key)
            let received = try await client.receive(count: 2)
            #expect(received == [config, key])
        }
    }

    // (b)
    @Test func wrongSecretIsRejectedAndTheDeviceIsNotAdded() async throws {
        try await ServerHarness.run(phones: ["Guesser"]) { harness, phones in
            _ = try harness.coordinator.start(port: harness.port)

            await #expect(throws: PairingHandshakeError.rejected) {
                try await harness.runPairing(phones[0], secret: .random(), expected: harness.host.fingerprint)
            }

            #expect(harness.store.all().isEmpty)
            try await harness.recorder.waitFor(.pairingFailed(.attempt(.invalidProof)))
            #expect(harness.coordinator.isOpen)
        }
    }

    // (c)
    @Test func pairingWhileTheWindowIsClosedIsRefusedAtTheTLSLevel() async throws {
        try await ServerHarness.run(phones: ["Early Phone"]) { harness, phones in
            let invitation = try harness.coordinator.start(port: harness.port)
            harness.coordinator.cancel()

            await #expect(throws: PairingHandshakeError.rejected) {
                try await harness.runPairing(phones[0], secret: invitation.secret, expected: invitation.hostFingerprint)
            }

            #expect(harness.store.all().isEmpty)
            // Never reached the application layer: no attempt was evaluated.
            #expect(harness.recorder.count(where: Self.isPairingFailure) == 0)
        }
    }

    // (d) window expired before the handshake
    @Test func expiredSecretIsRefused() async throws {
        try await ServerHarness.run(phones: ["Late Phone"]) { harness, phones in
            let invitation = try harness.coordinator.start(port: harness.port)
            harness.clock.advance(by: PairingSession.lifetime + 1)

            await #expect(throws: PairingHandshakeError.rejected) {
                try await harness.runPairing(phones[0], secret: invitation.secret, expected: invitation.hostFingerprint)
            }

            #expect(harness.store.all().isEmpty)
        }
    }

    // (d) window expired between the TLS handshake and the request
    @Test func secretExpiringMidConnectionIsRejectedByThePairingSession() async throws {
        try await ServerHarness.run(phones: ["Slow Phone"]) { harness, phones in
            let phone = phones[0]
            let invitation = try harness.coordinator.start(port: harness.port)
            let client = try harness.connect(phone)
            defer { client.close() }
            try await client.waitUntilReady()
            try await Task.sleep(for: .milliseconds(300))  // let the server classify it as a pairing connection
            harness.clock.advance(by: PairingSession.lifetime + 1)

            client.send(try PairingExchange.requestFrame(
                secret: invitation.secret, clientFingerprint: phone.fingerprint,
                serverFingerprint: harness.host.fingerprint, deviceName: "Slow Phone"
            ))

            try await client.waitUntilClosed()
            try await harness.recorder.waitFor(.pairingFailed(.attempt(.expired)))
            #expect(harness.store.all().isEmpty)
            #expect(client.frames.isEmpty)
        }
    }

    // (e)
    @Test func threeWrongAttemptsBurnTheSession() async throws {
        try await ServerHarness.run(phones: ["Brute Forcer"]) { harness, phones in
            let invitation = try harness.coordinator.start(port: harness.port)
            for _ in 0..<PairingSession.maxFailedAttempts {
                await #expect(throws: PairingHandshakeError.rejected) {
                    try await harness.runPairing(phones[0], secret: .random(), expected: nil)
                }
            }
            try await harness.recorder.waitFor(count: PairingSession.maxFailedAttempts, where: Self.isPairingFailure)
            #expect(!harness.coordinator.isOpen)

            await #expect(throws: PairingHandshakeError.rejected) {
                try await harness.runPairing(phones[0], secret: invitation.secret, expected: invitation.hostFingerprint)
            }
            #expect(harness.store.all().isEmpty)
        }
    }

    // (f)
    @Test func unpairedConnectionCannotEvictTheActivePairedSession() async throws {
        try await ServerHarness.run(phones: ["Owner", "Stranger"]) { harness, phones in
            let (owner, stranger) = (phones[0], phones[1])
            try harness.pair(owner)
            let active = try harness.connect(owner)
            defer { active.close() }
            try await harness.recorder.waitFor(.clientConnected(owner.fingerprint))
            _ = try harness.coordinator.start(port: harness.port)

            let intruder = try harness.connect(stranger)
            defer { intruder.close() }
            try await intruder.waitUntilReady()
            try await Task.sleep(for: .milliseconds(300))
            let config = Frame(type: .videoConfig, timestampMicros: 0, payload: Data([1]))
            let key = Frame(type: .videoFrame, flags: [.keyframe], timestampMicros: 1, payload: Data([2]))
            harness.server.broadcast(config)
            harness.server.broadcast(key)

            let received = try await active.receive(count: 2)

            #expect(received == [config, key])
            #expect(intruder.frames.isEmpty)
            #expect(!active.isClosed)
            #expect(!harness.recorder.contains(.clientDisconnected(owner.fingerprint)))
            #expect(harness.recorder.count(where: Self.isClientConnected) == 1)
        }
    }

    // (g)
    @Test func unpairedConnectionSendingInputIsDroppedAndNothingReachesTheHost() async throws {
        try await withPairingConnection { harness, intruder in
            intruder.send(try InputEventCoding.frame(for: .text("rm -rf"), timestampMicros: 0))

            try await intruder.waitUntilClosed()
            #expect(harness.recorder.count { if case .input = $0 { true } else { false } } == 0)
            try await harness.recorder.waitFor(count: 1, where: Self.isPairingFailure)
        }
    }

    // (g)
    @Test func unpairedConnectionAnnouncingAnOversizedFrameIsDropped() async throws {
        try await withPairingConnection { harness, intruder in
            var header = FrameEncoder.encode(Frame(type: .pairRequest, timestampMicros: 0, payload: Data()))
            withUnsafeBytes(of: UInt32(2_000_000).bigEndian) { header.replaceSubrange(10..<14, with: $0) }
            intruder.sendRaw(header)

            try await intruder.waitUntilClosed()
            #expect(harness.store.all().isEmpty)
        }
    }

    @Test func silentUnpairedConnectionIsDroppedAfterThePairRequestTimeout() async throws {
        try await withPairingConnection { harness, intruder in
            try await intruder.waitUntilClosed()
            try await harness.recorder.waitFor(.pairingFailed(.timedOut))
        }
    }

    @Test func unpairedConnectionsBeyondTheCapAreDropped() async throws {
        let limits = StreamServerLimits(
            maxHandshaking: 8, maxPairingConnections: 2, handshakeTimeout: 5, pairRequestTimeout: 5, pairingLinger: 1
        )
        try await ServerHarness.run(phones: ["A", "B", "C"], limits: limits) { harness, phones in
            _ = try harness.coordinator.start(port: harness.port)
            let first = try harness.connect(phones[0])
            let second = try harness.connect(phones[1])
            defer { first.close(); second.close() }
            try await first.waitUntilReady()
            try await second.waitUntilReady()
            try await Task.sleep(for: .milliseconds(200))

            let third = try harness.connect(phones[2])
            defer { third.close() }

            try await third.waitUntilClosed(timeout: .milliseconds(500))
            #expect(!first.isClosed && !second.isClosed)
        }
    }

    // (h)
    @Test func revokedDeviceIsDisconnectedAndCannotReconnect() async throws {
        try await ServerHarness.run(phones: ["Lost Phone"]) { harness, phones in
            let phone = phones[0]
            try harness.pair(phone)
            let client = try harness.connect(phone)
            defer { client.close() }
            try await harness.recorder.waitFor(.clientConnected(phone.fingerprint))

            try harness.store.remove(phone.fingerprint)
            harness.server.disconnect(deviceWith: phone.fingerprint)

            try await client.waitUntilClosed()
            try await harness.recorder.waitFor(.clientDisconnected(phone.fingerprint))
            let retry = try harness.connect(phone)
            defer { retry.close() }
            try await retry.waitUntilClosed()
            #expect(harness.recorder.count(where: Self.isClientConnected) == 1)
        }
    }

    // (i)
    @Test func clientPinningTheInvitationsFingerprintRefusesAnotherServerKey() async throws {
        try await ServerHarness.run(phones: ["Careful Phone", "Impostor Key"]) { harness, phones in
            let invitation = try harness.coordinator.start(port: harness.port)
            // The QR code names a different Mac than the one answering on this address.
            let forged = try PairingInvitation(
                host: invitation.host, port: invitation.port, hostFingerprint: phones[1].fingerprint, secret: invitation.secret
            )

            await #expect(throws: PairingHandshakeError.hostFingerprintMismatch) {
                try await harness.runPairing(phones[0], secret: forged.secret, expected: forged.hostFingerprint)
            }

            #expect(harness.store.all().isEmpty)
            #expect(harness.recorder.count(where: Self.isPairingFailure) == 0)
            #expect(harness.coordinator.isOpen)
        }
    }

    // MARK: Helpers

    /// An unpaired TLS connection that the server has classified as a pairing connection.
    private func withPairingConnection(_ body: (ServerHarness, TLSTestClient) async throws -> Void) async throws {
        try await ServerHarness.run(phones: ["Intruder"]) { harness, phones in
            _ = try harness.coordinator.start(port: harness.port)
            let intruder = try harness.connect(phones[0])
            defer { intruder.close() }
            try await intruder.waitUntilReady()
            try await Task.sleep(for: .milliseconds(200))
            try await body(harness, intruder)
        }
    }
}
