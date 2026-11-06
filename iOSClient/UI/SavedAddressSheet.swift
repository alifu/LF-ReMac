import RemoteCore
import SwiftUI

/// Lets the user save an address (a Tailscale IP or MagicDNS name) for a paired Mac, so the phone
/// can reach it away from home when Bonjour finds nothing. Calls `onFinished` when dismissed.
struct SavedAddressSheet: View {
    private let credentials: PhoneCredentials
    private let host: PairedHost
    private let onFinished: () -> Void
    @State private var hostText: String
    @State private var portText: String
    @State private var errorMessage: String?

    init(credentials: PhoneCredentials, host: PairedHost, onFinished: @escaping () -> Void) {
        self.credentials = credentials
        self.host = host
        self.onFinished = onFinished
        _hostText = State(initialValue: host.savedHost ?? "")
        _portText = State(initialValue: String(host.savedPort ?? SavedAddress.defaultPort))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Host or IP", text: $hostText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Port", text: $portText)
                        .keyboardType(.numberPad)
                } footer: {
                    Text("Use the Mac's Tailscale IP (100.x.y.z) or its MagicDNS name.")
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                }
                if host.savedHost != nil || host.savedPort != nil {
                    Section {
                        Button("Remove saved address", role: .destructive, action: remove)
                    }
                }
            }
            .navigationTitle("Set Address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onFinished() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                }
            }
        }
    }

    private func save() {
        switch SavedAddress.validate(hostText: hostText, portText: portText) {
        case .failure(let error):
            errorMessage = error.message
        case .success(let address):
            store(host.withSavedAddress(host: address.host, port: address.port))
        }
    }

    private func remove() {
        store(host.withSavedAddress(host: nil, port: nil))
    }

    /// Writes the change onto the freshest stored copy, so a connection that updated the
    /// last-known address while this sheet was open is not undone.
    private func store(_ change: PairedHost) {
        let current = credentials.hostStore.peer(with: host.fingerprint) ?? host
        do {
            try credentials.hostStore.add(
                current.withSavedAddress(host: change.savedHost, port: change.savedPort)
            )
            onFinished()
        } catch {
            errorMessage = "Could not save the address. Try again."
        }
    }
}
