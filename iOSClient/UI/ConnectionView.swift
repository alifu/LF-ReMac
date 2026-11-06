import Network
import RemoteCore
import SwiftUI

/// Entry screen: connect to a paired Mac (pinned TLS), then show the stream.
/// Pairing UI arrives in task 4.5; until then unpaired Macs only show a placeholder notice.
struct ConnectionView: View {
    private static let pairingComingSoon = "Pairing screen coming soon."

    private let credentials: PhoneCredentials
    @State private var client: StreamClient
    @State private var browser = HostBrowser()
    @State private var pairedHosts: [PairedHost] = []
    @State private var notice: String?

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
    }

    private var hostPicker: some View {
        NavigationStack {
            List {
                statusSection
                pairedSection
                discoveredSection
                ManualAddressSection { notice = Self.pairingComingSoon }
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
        if let notice {
            Section { Label(notice, systemImage: "info.circle") }
        }
    }

    private var pairedSection: some View {
        Section("Paired Macs") {
            if pairedHosts.isEmpty {
                Text("No paired Mac yet.").foregroundStyle(.secondary)
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
                Button("Pair with \(host.name)") { notice = Self.pairingComingSoon }
            }
        }
    }

    private func reloadPairedHosts() {
        pairedHosts = credentials.hostStore.all().sorted { $0.name < $1.name }
    }
}

private struct ManualAddressSection: View {
    let onPair: () -> Void
    @State private var host = ""
    @State private var portText = String(NetworkDefaults.port)

    var body: some View {
        Section("Pair by address") {
            TextField("Host or IP (e.g. 192.168.1.20)", text: $host)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            TextField("Port", text: $portText)
                .keyboardType(.numberPad)
            Button("Pair", action: onPair)
                .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

#Preview {
    ConnectionView(credentials: PhoneCredentials.live())
}
