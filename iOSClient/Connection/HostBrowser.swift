import Foundation
import Network
import Observation
import RemoteCore

struct DiscoveredHost: Identifiable, Equatable, Sendable {
    let name: String
    let endpoint: NWEndpoint

    var id: String { name }
}

/// Finds LF-ReMac hosts on the local network via Bonjour.
@MainActor
@Observable
final class HostBrowser {
    private(set) var hosts: [DiscoveredHost] = []
    private(set) var errorMessage: String?

    private let logger = AppLog.logger(category: "browser")
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(
            for: .bonjour(type: NetworkDefaults.bonjourServiceType, domain: nil),
            using: .tcp
        )
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.handle(state: state) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = Self.hosts(from: results)
            Task { @MainActor in self?.hosts = found }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        hosts = []
    }

    private func handle(state: NWBrowser.State) {
        switch state {
        case .failed(let error):
            logger.error("Browse failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        case .waiting(let error):
            // Typically: Local Network permission denied.
            errorMessage = error.localizedDescription
        case .ready:
            errorMessage = nil
        default:
            break
        }
    }

    nonisolated private static func hosts(from results: Set<NWBrowser.Result>) -> [DiscoveredHost] {
        results
            .compactMap { result -> DiscoveredHost? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return DiscoveredHost(name: name, endpoint: result.endpoint)
            }
            .sorted { $0.name < $1.name }
    }
}
