import Foundation
import Network
import Testing
@testable import MacHost

struct ConnectionSourceTests {
    private func source(_ host: String, port: UInt16 = 1) -> ConnectionSource {
        ConnectionSource(endpoint: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any))
    }

    @Test func portDoesNotMatter() {
        #expect(source("192.168.1.20", port: 50000) == source("192.168.1.20", port: 50001))
        #expect(source("192.168.1.20") != source("192.168.1.21"))
    }

    @Test func ipv6ZoneIsIgnoredAndMappedIPv4CountsAsIPv4() {
        #expect(source("fe80::1%lo0") == source("fe80::1"))
        #expect(source("::ffff:192.168.1.20") == source("192.168.1.20"))
        #expect(source("fe80::1") != source("fe80::2"))
    }

    @Test func endpointsWithoutAnAddressShareOneBucket() {
        #expect(ConnectionSource(endpoint: nil) == .unknown)
        #expect(ConnectionSource(endpoint: .service(name: "x", type: "_t._tcp", domain: "local", interface: nil)) == .unknown)
    }
}

struct HandshakeAdmissionTests {
    private let limits = ServerHarness.limits(maxHandshaking: 4, perAddressHandshaking: 2)
    private let attacker = ConnectionSource(endpoint: .hostPort(host: "10.0.0.66", port: 1))
    private let phone = ConnectionSource(endpoint: .hostPort(host: "10.0.0.7", port: 1))

    @Test func oneAddressIsCappedWhileOthersStillGetIn() {
        let busy = [attacker, attacker]

        #expect(HandshakeAdmission.decide(for: attacker, inProgress: busy, limits: limits) == .tooManyFromAddress)
        #expect(HandshakeAdmission.decide(for: phone, inProgress: busy, limits: limits) == .admitted)
    }

    @Test func globalCapStillApplies() {
        let others = (1...4).map { ConnectionSource(endpoint: .hostPort(host: NWEndpoint.Host("10.0.1.\($0)"), port: 1)) }

        #expect(HandshakeAdmission.decide(for: phone, inProgress: others, limits: limits) == .tooManyInTotal)
    }

    @Test func standardLimitsMatchTheSecurityReview() {
        let standard = StreamServerLimits.standard

        #expect(standard.maxHandshaking == 32)
        #expect(standard.maxHandshakingPerAddress == 2)
        #expect(standard.maxPairingConnectionsPerAddress == 1)
        #expect(standard.handshakeTimeout == StreamServerLimits.standardHandshakeTimeout)
        #expect(standard.handshakeTimeout <= 3)
        #expect(standard.pairRequestTimeout <= 5)
    }
}
