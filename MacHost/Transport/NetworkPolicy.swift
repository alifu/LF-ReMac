import Foundation
import Network

/// Which remote addresses may even start a TLS handshake with this Mac.
///
/// The listener binds every interface (Network.framework cannot bind a listener to an address
/// range), so the source address is checked as soon as a connection arrives. Public addresses are
/// always refused: a port forward or an IPv6 firewall hole never exposes the Mac. Tailscale
/// addresses are refused unless the user turned them on. Pure, so it is unit-testable.
struct NetworkPolicy: Equatable, Sendable {
    var allowsTailscale: Bool

    static let lanOnly = NetworkPolicy(allowsTailscale: false)
    static let lanAndTailscale = NetworkPolicy(allowsTailscale: true)

    func allows(_ endpoint: NWEndpoint?) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        return allows(host)
    }

    func allows(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let address):
            return allows(ipv4: [UInt8](address.rawValue))
        case .ipv6(let address):
            if let mapped = address.asIPv4 { return allows(ipv4: [UInt8](mapped.rawValue)) }
            return allows(ipv6: [UInt8](address.rawValue))
        case .name:
            return false
        @unknown default:
            return false
        }
    }

    private func allows(ipv4 b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        if b[0] == 127 { return true }                               // loopback
        if b[0] == 10 { return true }                                // 10.0.0.0/8
        if b[0] == 172, (16...31).contains(b[1]) { return true }     // 172.16.0.0/12
        if b[0] == 192, b[1] == 168 { return true }                  // 192.168.0.0/16
        if b[0] == 169, b[1] == 254 { return true }                  // link-local
        if b[0] == 100, (64...127).contains(b[1]) { return allowsTailscale }  // 100.64.0.0/10
        return false
    }

    private func allows(ipv6 b: [UInt8]) -> Bool {
        guard b.count == 16 else { return false }
        if b.dropLast().allSatisfy({ $0 == 0 }), b[15] == 1 { return true }  // ::1
        if b[0] == 0xfe, b[1] & 0xc0 == 0x80 { return true }                 // fe80::/10
        if b[0] == 0xfd, b[1] == 0x7a, b[2] == 0x11, b[3] == 0x5c, b[4] == 0xa1, b[5] == 0xe0 {
            return allowsTailscale                                            // fd7a:115c:a1e0::/48
        }
        return b[0] & 0xfe == 0xfc                                            // fc00::/7 unique local
    }
}
