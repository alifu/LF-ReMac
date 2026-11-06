import Foundation
import Network
import RemoteCore

/// Where to dial a paired Mac. Bonjour names and addresses are only hints: whoever answers must
/// still present the pinned key in the TLS handshake. Anyone on the LAN can advertise the Mac's
/// name, so a paired Mac has an ordered list of candidates that are tried in turn.
enum PairedHostTarget {
    /// Every Bonjour service with the Mac's name (sorted, for a stable order), then the user's saved
    /// address, then its last known address. Empty when there is nothing to dial.
    static func candidates(for host: PairedHost, discovered: [DiscoveredHost]) -> [NWEndpoint] {
        let services = discovered
            .filter { $0.name == host.name }
            .map(\.endpoint)
            .sorted { $0.debugDescription < $1.debugDescription }
        return unique(services + addresses(of: host))
    }

    /// `preferred` first (e.g. the row the user tapped), then the saved and last known addresses.
    static func candidates(preferring preferred: NWEndpoint, for host: PairedHost) -> [NWEndpoint] {
        unique([preferred] + addresses(of: host))
    }

    /// The first candidate, if any (whether the Mac can be dialled at all).
    static func endpoint(for host: PairedHost, discovered: [DiscoveredHost]) -> NWEndpoint? {
        candidates(for: host, discovered: discovered).first
    }

    /// Discovered Macs that do not correspond to any paired Mac (candidates for pairing).
    static func unpaired(_ discovered: [DiscoveredHost], paired: [PairedHost]) -> [DiscoveredHost] {
        let names = Set(paired.map(\.name))
        return discovered.filter { !names.contains($0.name) }
    }

    static func lastKnownEndpoint(of host: PairedHost) -> NWEndpoint? {
        endpoint(address: host.lastKnownHost, port: host.lastKnownPort)
    }

    static func savedEndpoint(of host: PairedHost) -> NWEndpoint? {
        endpoint(address: host.savedHost, port: host.savedPort)
    }

    /// The user's saved address, then the last known address (both optional).
    private static func addresses(of host: PairedHost) -> [NWEndpoint] {
        [savedEndpoint(of: host), lastKnownEndpoint(of: host)].compactMap { $0 }
    }

    private static func endpoint(address: String?, port rawPort: UInt16?) -> NWEndpoint? {
        guard let address, !address.isEmpty,
              let rawPort, let port = NWEndpoint.Port(rawValue: rawPort) else {
            return nil
        }
        return .hostPort(host: NWEndpoint.Host(address), port: port)
    }

    private static func unique(_ endpoints: [NWEndpoint]) -> [NWEndpoint] {
        endpoints.reduce(into: [NWEndpoint]()) { result, endpoint in
            if !result.contains(endpoint) { result.append(endpoint) }
        }
    }
}
