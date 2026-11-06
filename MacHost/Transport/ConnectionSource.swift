import Foundation
import Network

/// The remote IP of a connection, used only to share connection quotas fairly between LAN hosts.
///
/// Normalised so one host cannot dodge its quota: the port is ignored, IPv6 zone/interface is
/// ignored (an attacker could otherwise multiply its quota by reaching us via several scopes) and
/// IPv4-mapped IPv6 counts as the IPv4 address. Endpoints without a usable IP share one bucket.
struct ConnectionSource: Hashable, Sendable {
    let key: String

    static let unknown = ConnectionSource(key: "unknown")

    init(endpoint: NWEndpoint?) {
        guard case .hostPort(let host, _) = endpoint else {
            self = .unknown
            return
        }
        self.init(host: host)
    }

    init(host: NWEndpoint.Host) {
        switch host {
        case .ipv4(let address):
            self.init(key: "v4:" + Self.hex(address.rawValue))
        case .ipv6(let address):
            if let mapped = address.asIPv4 {
                self.init(key: "v4:" + Self.hex(mapped.rawValue))
            } else {
                // `rawValue` is the 16 address bytes only; the zone is not part of it.
                self.init(key: "v6:" + Self.hex(address.rawValue))
            }
        case .name(let name, _):
            self.init(key: "name:" + name.lowercased())
        @unknown default:
            self = .unknown
        }
    }

    private init(key: String) {
        self.key = key
    }

    private static func hex(_ bytes: Data) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
