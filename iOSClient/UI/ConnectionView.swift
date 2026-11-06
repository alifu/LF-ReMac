import Network
import RemoteCore
import SwiftUI

/// Entry screen: connect to a paired Mac (pinned TLS), then show the stream.
struct ConnectionView: View {
    private let credentials: PhoneCredentials
    @State private var client: StreamClient
    @State private var browser = HostBrowser()
    @State private var pairedHosts: [PairedHost] = []
    @State private var pairingRequest: PairingRequest?

    init(credentials: PhoneCredentials) {
        self.credentials = credentials
        _client = State(initialValue: StreamClient(credentials: credentials))
    }

    var body: some View {
        Group {
            if case .connected(let name) = client.state {
                StreamView(client: client, hostName: name)
            } else {
                hostPicker
            }
        }
        .task {
            reloadPairedHosts()
            browser.start()
        }
        .onDisappear {
            browser.stop()
        }
        .sheet(item: $pairingRequest) { request in
            PairingSheet(
                credentials: credentials,
                discovered: browser.hosts,
                request: request
            ) {
                pairingRequest = nil
                reloadPairedHosts()
            }
        }
    }

    private var hostPicker: some View {
        NavigationStack {
            List {
                statusSection
                pairedSection
                discoveredSection
            }
            .navigationTitle("LF-ReMac")
            .refreshable { reloadPairedHosts() }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch client.state {
        case .connecting(let name):
            Section { Label("Connecting to \(name)…", systemImage: "arrow.triangle.2.circlepath") }
        case .failed(let message):
            Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
        case .idle, .connected:
            EmptyView()
        }
    }

    private var pairedSection: some View {
        Section("Paired Macs") {
            if pairedHosts.isEmpty {
                Text("No paired Mac yet.").foregroundStyle(.secondary)
            }
            Button("Pair New Mac…", systemImage: "qrcode.viewfinder") {
                pairingRequest = PairingRequest(mode: .scan)
            }
            ForEach(pairedHosts, id: \.fingerprint) { host in
                if let endpoint = PairedHostTarget.endpoint(for: host, discovered: browser.hosts) {
                    Button(host.name) { client.connect(to: endpoint, host: host) }
                } else {
                    LabeledContent(host.name, value: "Not found on this network")
                }
            }
        }
    }

    private var discoveredSection: some View {
        Section("Other Macs on this network") {
            let unpaired = PairedHostTarget.unpaired(browser.hosts, paired: pairedHosts)
            if unpaired.isEmpty {
                Text(browser.errorMessage ?? "Searching… start hosting on your Mac.")
                    .foregroundStyle(.secondary)
            }
            ForEach(unpaired) { host in
                Button("Pair with \(host.name)") {
                    pairingRequest = PairingRequest(mode: .type, preselectedHostName: host.name)
                }
            }
        }
    }

    private func reloadPairedHosts() {
        pairedHosts = credentials.hostStore.all().sorted { $0.name < $1.name }
    }
}

/// Owns the pairing model for the lifetime of one presented sheet.
private struct PairingSheet: View {
    let discovered: [DiscoveredHost]
    let request: PairingRequest
    let onFinished: () -> Void
    @State private var model: PairingModel

    init(credentials: PhoneCredentials, discovered: [DiscoveredHost], request: PairingRequest, onFinished: @escaping () -> Void) {
        self.discovered = discovered
        self.request = request
        self.onFinished = onFinished
        _model = State(initialValue: PairingModel(service: PairingService(credentials: credentials)))
    }

    var body: some View {
        PairingFlowView(model: model, discovered: discovered, request: request, onFinished: onFinished)
    }
}

#Preview {
    ConnectionView(credentials: PhoneCredentials.live())
}
