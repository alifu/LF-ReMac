import Network
import RemoteCore
import SwiftUI

/// Entry screen: connect to a paired Mac (pinned TLS), then show the stream.
struct ConnectionView: View {
    private let credentials: PhoneCredentials
    @State private var pairedHostsIssue: String?
    @State private var isConfirmingReset = false
    @State private var client: StreamClient
    @State private var browser = HostBrowser()
    @State private var pairedHosts: [PairedHost] = []
    @State private var pairingRequest: PairingRequest?
    @State private var hostPendingForget: PairedHost?
    @State private var forgetError: String?
    @State private var hostPendingAddress: PairedHost?

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
        .confirmationDialog("Reset the paired Macs list?", isPresented: $isConfirmingReset, titleVisibility: .visible) {
            Button("Reset and Forget All Macs", role: .destructive) { resetPairedHosts() }
        } message: {
            Text("The damaged list is erased. You must pair each Mac again.")
        }
        .sheet(isPresented: isEditingAddress) {
            if let host = hostPendingAddress {
                SavedAddressSheet(credentials: credentials, host: host) {
                    hostPendingAddress = nil
                    reloadPairedHosts()
                }
            }
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
                issueSection
                pairedSection
                discoveredSection
            }
            .navigationTitle("LF-ReMac")
            .refreshable { reloadPairedHosts() }
        }
    }

    @ViewBuilder
    private var issueSection: some View {
        if let issue = pairedHostsIssue {
            Section {
                Text(issue).font(.callout).foregroundStyle(.orange)
                Button("Reset Paired Macs…", role: .destructive) { isConfirmingReset = true }
            }
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
                pairedRow(host)
                    .swipeActions {
                        Button("Set Address…") { hostPendingAddress = host }
                            .tint(.blue)
                        Button("Forget", role: .destructive) { hostPendingForget = host }
                    }
            }
            if let forgetError {
                Label(forgetError, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
        }
        .confirmationDialog(
            "Forget this Mac?",
            isPresented: Binding(get: { hostPendingForget != nil }, set: { if !$0 { hostPendingForget = nil } }),
            titleVisibility: .visible,
            presenting: hostPendingForget
        ) { host in
            Button("Forget \(host.name)", role: .destructive) { forget(host) }
        } message: { host in
            Text("You will need to pair with \(host.name) again to reconnect.")
        }
    }

    @ViewBuilder
    private func pairedRow(_ host: PairedHost) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if !PairedHostTarget.candidates(for: host, discovered: browser.hosts).isEmpty {
                Button(host.name) { client.connect(to: host, discovered: browser.hosts) }
            } else {
                LabeledContent(host.name, value: "Not found on this network")
            }
            Text("Key \(host.fingerprint.verificationCode)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            if let savedHost = host.savedHost, let savedPort = host.savedPort {
                Text("Saved: \(savedHost):\(savedPort)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var isEditingAddress: Binding<Bool> {
        Binding(get: { hostPendingAddress != nil }, set: { if !$0 { hostPendingAddress = nil } })
    }

    private func forget(_ host: PairedHost) {
        hostPendingForget = nil
        do {
            try credentials.hostStore.remove(host.fingerprint)
            forgetError = nil
        } catch {
            forgetError = "Could not forget \(host.name). Try again."
        }
        reloadPairedHosts()
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

    private func resetPairedHosts() {
        try? credentials.resetPairedHosts()
        reloadPairedHosts()
    }

    private func reloadPairedHosts() {
        pairedHosts = credentials.hostStore.all().sorted { $0.name < $1.name }
        pairedHostsIssue = credentials.pairedHostsIssue
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
        _model = State(initialValue: PairingModel(
            service: PairingService(credentials: credentials),
            pairedHosts: { credentials.hostStore.all() }
        ))
    }

    var body: some View {
        PairingFlowView(model: model, discovered: discovered, request: request, onFinished: onFinished)
    }
}

#Preview {
    ConnectionView(credentials: PhoneCredentials.live())
}
