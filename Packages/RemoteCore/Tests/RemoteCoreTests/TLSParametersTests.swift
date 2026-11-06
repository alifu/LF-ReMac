import Foundation
import Network
import Security
import Testing
@testable import RemoteCore

/// Real TLS 1.3 handshakes over loopback with two throw-away Keychain identities.
@Suite(.serialized)
struct TLSParametersTests {
    private let message = Data("hello over pinned mutual TLS".utf8)

    @Test func handshakeSucceedsAndBytesFlowWhenBothSidesPinEachOther() async throws {
        try await withIdentities { host, phone in
            let server = try TLSEchoServer(parameters: TLSParameters.server(identity: host) { $0 == phone.fingerprint })
            let port = try #require(await server.start())
            defer { server.stop() }

            let result = await TLSLoopback.exchange(
                message, port: port, parameters: try TLSParameters.client(identity: phone) { $0 == host.fingerprint }
            )

            #expect(result == .echoed(message, serverFingerprint: host.fingerprint))
            #expect(server.readyPeerFingerprints == [phone.fingerprint])
        }
    }

    @Test func handshakeFailsWhenServerDoesNotPinTheClient() async throws {
        try await withIdentities { host, phone in
            let server = try TLSEchoServer(parameters: TLSParameters.server(identity: host) { _ in false })
            let port = try #require(await server.start())
            defer { server.stop() }

            let result = await TLSLoopback.exchange(
                message, port: port, parameters: try TLSParameters.client(identity: phone) { $0 == host.fingerprint }
            )

            #expect(result == .failed)
            #expect(server.readyPeerFingerprints.isEmpty)
        }
    }

    @Test func handshakeFailsWhenClientPinsADifferentServerFingerprint() async throws {
        try await withIdentities { host, phone in
            let server = try TLSEchoServer(parameters: TLSParameters.server(identity: host) { $0 == phone.fingerprint })
            let port = try #require(await server.start())
            defer { server.stop() }
            let wrong = try DeviceFingerprint(bytes: Data(repeating: 0xAB, count: 32))

            let result = await TLSLoopback.exchange(
                message, port: port, parameters: try TLSParameters.client(identity: phone) { $0 == wrong }
            )

            #expect(result == .failed)
            #expect(server.readyPeerFingerprints.isEmpty)
        }
    }

    @Test func handshakeFailsWhenClientPresentsNoCertificate() async throws {
        try await withIdentities { host, phone in
            let server = try TLSEchoServer(parameters: TLSParameters.server(identity: host) { $0 == phone.fingerprint })
            let port = try #require(await server.start())
            defer { server.stop() }

            let result = await TLSLoopback.exchange(message, port: port, parameters: Self.anonymousClient(pinning: host.fingerprint))

            #expect(result == .failed)
            #expect(server.readyPeerFingerprints.isEmpty)
        }
    }

    @Test func handshakeFailsWhenAnotherDeviceImpersonatesThePairedPhone() async throws {
        try await withIdentities { host, phone in
            try await TestIdentity.withIdentity(name: "Intruder") { intruder, _ in
                let server = try TLSEchoServer(parameters: TLSParameters.server(identity: host) { $0 == phone.fingerprint })
                let port = try #require(await server.start())
                defer { server.stop() }

                let result = await TLSLoopback.exchange(
                    message, port: port, parameters: try TLSParameters.client(identity: intruder) { $0 == host.fingerprint }
                )

                #expect(result == .failed)
                #expect(server.readyPeerFingerprints.isEmpty)
            }
        }
    }

    @Test func everyReconnectRunsBothVerifyBlocksSoARevocationApplies() async throws {
        try await withIdentities { host, phone in
            let serverChecks = Counter()
            let clientChecks = Counter()
            let allowed = Flag(true)
            let server = try TLSEchoServer(parameters: TLSParameters.server(identity: host) { fingerprint in
                serverChecks.increment()
                return allowed.value && fingerprint == phone.fingerprint
            })
            let port = try #require(await server.start())
            defer { server.stop() }
            // One parameters object for every connection, as a resumption cache would key on it.
            let client = try TLSParameters.client(identity: phone) { fingerprint in
                clientChecks.increment()
                return fingerprint == host.fingerprint
            }

            let first = await TLSLoopback.exchange(message, port: port, parameters: client)
            let second = await TLSLoopback.exchange(message, port: port, parameters: client)
            allowed.value = false
            let revoked = await TLSLoopback.exchange(message, port: port, parameters: client)

            #expect(first == .echoed(message, serverFingerprint: host.fingerprint))
            #expect(second == first)
            #expect(revoked == .failed)
            #expect(serverChecks.value == 3)
            #expect(clientChecks.value == 3)
        }
    }

    // MARK: Helpers

    private func withIdentities(_ body: (DeviceIdentity, DeviceIdentity) async throws -> Void) async throws {
        try await TestIdentity.withIdentity(name: "Loopback Host") { host, _ in
            try await TestIdentity.withIdentity(name: "Loopback Phone") { phone, _ in
                try await body(host, phone)
            }
        }
    }

    /// TLS 1.3 client that pins the server but has no certificate of its own.
    private static func anonymousClient(pinning fingerprint: DeviceFingerprint) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            complete(TLSParameters.peerFingerprint(from: trust) == fingerprint)
        }, DispatchQueue(label: "anonymous-client-verify"))
        return NWParameters(tls: tls)
    }
}
