import Network
import RemoteCore
import SwiftUI

/// Entry screen: pick a discovered Mac or type an address, then show the stream.
struct ConnectionView: View {
    @State private var client = StreamClient()
    @State private var browser = HostBrowser()

    var body: some View {
        Group {
            if case .connected(let name) = client.state {
                StreamView(client: client, hostName: name)
            } else {
                hostPicker
            }
        }
        .task {
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
                discoveredSection
                ManualAddressSection(onConnect: connectManually)
            }
            .navigationTitle("LF-ReMac")
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

    private var discoveredSection: some View {
        Section("Macs on this network") {
            if browser.hosts.isEmpty {
                Text(browser.errorMessage ?? "Searching… start hosting on your Mac.")
                    .foregroundStyle(.secondary)
            }
            ForEach(browser.hosts) { host in
                Button(host.name) { client.connect(to: host.endpoint, name: host.name) }
            }
        }
    }

    private func connectManually(host: String, port: UInt16) {
        guard let port = NWEndpoint.Port(rawValue: port), !host.isEmpty else { return }
        client.connect(to: .hostPort(host: NWEndpoint.Host(host), port: port), name: host)
    }
}

private struct ManualAddressSection: View {
    let onConnect: (String, UInt16) -> Void
    @State private var host = ""
    @State private var portText = String(NetworkDefaults.port)

    var body: some View {
        Section("Connect by address") {
            TextField("Host or IP (e.g. 192.168.1.20)", text: $host)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            TextField("Port", text: $portText)
                .keyboardType(.numberPad)
            Button("Connect") {
                onConnect(host.trimmingCharacters(in: .whitespaces), UInt16(portText) ?? NetworkDefaults.port)
            }
            .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

#Preview {
    ConnectionView()
}
