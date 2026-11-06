import Foundation
import Network
import os
import Testing
@testable import RemoteCore

/// `PairingHandshake` against a scripted TLS host over loopback (real TLS, throw-away identities).
@Suite(.serialized)
struct PairingHandshakeTests {
    private let secret = Fixtures.secret(seed: 42)

    @Test func succeedsAgainstAHostThatKnowsTheSecret() async throws {
        try await withHost(reply: .honest(secret)) { host, phone, port in
            let result = try await run(phone: phone, port: port, expected: host.fingerprint)

            #expect(result.hostFingerprint == host.fingerprint)
            #expect(result.hostName == "Fake Mac")
            #expect(result.remotePort == port)
        }
    }

    @Test func manualFlowWithoutExpectedFingerprintStillLearnsTheHandshakeFingerprint() async throws {
        try await withHost(reply: .honest(secret)) { host, phone, port in
            let result = try await run(phone: phone, port: port, expected: nil)

            #expect(result.hostFingerprint == host.fingerprint)
        }
    }

    @Test func refusesAHostWhoseKeyDiffersFromTheInvitation() async throws {
        try await withHost(reply: .honest(secret)) { _, phone, port in
            await #expect(throws: PairingHandshakeError.hostFingerprintMismatch) {
                try await run(phone: phone, port: port, expected: Fixtures.attacker)
            }
        }
    }

    @Test func refusesAnImpostorThatDoesNotKnowTheSecret() async throws {
        try await withHost(reply: .honest(Fixtures.secret(seed: 43))) { _, phone, port in
            await #expect(throws: PairingHandshakeError.invalidHostProof) {
                try await run(phone: phone, port: port, expected: nil)
            }
        }
    }

    @Test func hostClosingWithoutReplyIsARejection() async throws {
        try await withHost(reply: .close) { host, phone, port in
            await #expect(throws: PairingHandshakeError.rejected) {
                try await run(phone: phone, port: port, expected: host.fingerprint)
            }
        }
    }

    @Test func garbageReplyIsAnInvalidResponse() async throws {
        try await withHost(reply: .garbage) { host, phone, port in
            await #expect(throws: PairingHandshakeError.invalidResponse) {
                try await run(phone: phone, port: port, expected: host.fingerprint)
            }
        }
    }

    @Test func silentHostTimesOut() async throws {
        try await withHost(reply: .silent) { host, phone, port in
            await #expect(throws: PairingHandshakeError.timedOut) {
                try await run(phone: phone, port: port, expected: host.fingerprint, timeout: .milliseconds(600))
            }
        }
    }

    @Test func closedPortCannotBeReached() async throws {
        _ = try await TestIdentity.withIdentity(name: "Lonely Phone") { phone, _ in
            let port = try await Self.unusedPort()
            await #expect(throws: PairingHandshakeError.cannotReach) {
                try await run(phone: phone, port: port, expected: nil)
            }
        }
    }

    @Test func invalidDeviceNameIsRefusedBeforeConnecting() async throws {
        _ = try await TestIdentity.withIdentity(name: "Phone") { phone, _ in
            await #expect(throws: PairingHandshakeError.invalidDeviceName) {
                try await PairingHandshake.run(
                    endpoint: .hostPort(host: "127.0.0.1", port: 9), identity: phone, secret: secret,
                    expectedHostFingerprint: nil, deviceName: ""
                )
            }
        }
    }

    // MARK: Helpers

    private func run(
        phone: DeviceIdentity, port: UInt16, expected: DeviceFingerprint?, timeout: Duration = .seconds(5)
    ) async throws -> PairingHandshakeResult {
        try await PairingHandshake.run(
            endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any),
            identity: phone, secret: secret, expectedHostFingerprint: expected, deviceName: "Test iPhone", timeout: timeout
        )
    }

    private func withHost(
        reply: FakePairingHost.Reply,
        _ body: (DeviceIdentity, DeviceIdentity, UInt16) async throws -> Void
    ) async throws {
        try await TestIdentity.withIdentity(name: "Fake Mac") { host, _ in
            try await TestIdentity.withIdentity(name: "Test iPhone") { phone, _ in
                let server = try FakePairingHost(identity: host, reply: reply)
                let port = try #require(await server.start())
                defer { server.stop() }
                try await body(host, phone, port)
            }
        }
    }

    private static func unusedPort() async throws -> UInt16 {
        let listener = try TLSEchoServer(parameters: .tcp)
        let port = try #require(await listener.start())
        listener.stop()
        return port
    }
}

/// TLS host that accepts any client key and answers one `pairRequest` as scripted.
private final class FakePairingHost: Sendable {
    enum Reply: Sendable {
        /// Responds with a host proof computed with this secret.
        case honest(PairingSecret)
        case close
        case garbage
        case silent
    }

    private let server: TLSEchoServer
    private let identity: DeviceIdentity
    private let reply: Reply
    private let queue = DispatchQueue(label: "fake-pairing-host")
    private let connections = OSAllocatedUnfairLock<[NWConnection]>(initialState: [])

    init(identity: DeviceIdentity, reply: Reply) throws {
        self.identity = identity
        self.reply = reply
        let parameters = try TLSParameters.server(identity: identity) { _ in true }
        server = try TLSEchoServer(parameters: parameters)
    }

    func start() async -> UInt16? {
        let port = await server.start()
        server.listener.newConnectionHandler = { [self] connection in accept(connection) }
        return port
    }

    func stop() {
        server.stop()
        connections.withLock { $0.forEach { $0.cancel() } }
    }

    private func accept(_ connection: NWConnection) {
        connections.withLock { $0.append(connection) }
        connection.stateUpdateHandler = { [self] state in
            if case .ready = state { awaitRequest(on: connection) }
        }
        connection.start(queue: queue)
    }

    private func awaitRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: PairingExchange.maxReadBytes) { [self] data, _, _, _ in
            var decoder = PairingExchange.requestDecoder()
            guard let data, let frame = (try? decoder.append(data))?.first,
                  let client = TLSParameters.peerFingerprint(of: connection) else { return connection.cancel() }
            answer(frame, client: client, on: connection)
        }
    }

    private func answer(_ frame: Frame, client: DeviceFingerprint, on connection: NWConnection) {
        switch reply {
        case .honest(let secret):
            let proof = PairingProof.host(secret: secret, client: client, server: identity.fingerprint)
            guard let response = try? PairingExchange.responseFrame(hostName: "Fake Mac", hostProof: proof) else { return }
            connection.send(content: FrameEncoder.encode(response), completion: .contentProcessed { _ in })
        case .close:
            connection.cancel()
        case .garbage:
            connection.send(content: Data([0xFF, 0, 0]), completion: .contentProcessed { _ in })
        case .silent:
            break
        }
    }
}
