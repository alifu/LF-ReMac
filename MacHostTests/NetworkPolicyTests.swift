import Network
import Testing
@testable import MacHost

struct NetworkPolicyTests {
    private func host(_ text: String) throws -> NWEndpoint.Host {
        if let v4 = IPv4Address(text) { return .ipv4(v4) }
        return .ipv6(try #require(IPv6Address(text)))
    }

    @Test(arguments: ["127.0.0.1", "10.1.2.3", "172.16.0.5", "172.31.255.1", "192.168.1.20", "169.254.3.4",
                      "::1", "fe80::1", "fd12:3456::1", "::ffff:192.168.1.5"])
    func lanAddressesAreAlwaysAllowed(_ text: String) throws {
        #expect(NetworkPolicy.lanOnly.allows(try host(text)))
    }

    @Test(arguments: ["8.8.8.8", "172.32.0.1", "172.15.0.1", "100.63.0.1", "100.128.0.1", "192.169.0.1",
                      "2001:4860:4860::8888", "::ffff:8.8.8.8"])
    func publicAddressesAreNeverAllowed(_ text: String) throws {
        #expect(!NetworkPolicy.lanAndTailscale.allows(try host(text)))
    }

    @Test(arguments: ["100.64.0.1", "100.100.1.1", "100.127.255.254", "fd7a:115c:a1e0::1"])
    func tailscaleAddressesNeedTheOptIn(_ text: String) throws {
        #expect(!NetworkPolicy.lanOnly.allows(try host(text)))
        #expect(NetworkPolicy.lanAndTailscale.allows(try host(text)))
    }

    @Test func hostNamesAndMissingEndpointsAreRefused() {
        #expect(!NetworkPolicy.lanAndTailscale.allows(.name("example.com", nil)))
        #expect(!NetworkPolicy.lanAndTailscale.allows(nil as NWEndpoint?))
    }
}
