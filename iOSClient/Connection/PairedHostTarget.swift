import Foundation
import Network
import RemoteCore

/// Where to dial a paired Mac. Bonjour names and addresses are only hints: whoever answers must
/// still present the pinned key in the TLS handshake.
enum PairedHostTarget {
    /// Prefers a Bonjour service with the Mac's name, else its last known address.
    static func endpoint(for host: PairedHost, discovered: [DiscoveredHost]) -> NWEndpoint? {
        if let match = discovered.first(where: { $0.name == host.name }) {
            return match.endpoint
        }
        guard let address = host.lastKnownHost, !address.isEmpty,
              let rawPort = host.lastKnownPort, let port = NWEndpoint.Port(rawValue: rawPort) else {
            return nil
        }
        return .hostPort(host: NWEndpoint.Host(address), port: port)
    }

    /// Discovered Macs that do not correspond to any paired Mac (candidates for pairing).
    static func unpaired(_ discovered: [DiscoveredHost], paired: [PairedHost]) -> [DiscoveredHost] {
        let names = Set(paired.map(\.name))
        return discovered.filter { !names.contains($0.name) }
    }
}
