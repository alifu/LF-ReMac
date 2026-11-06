import RemoteCore
import SwiftUI

/// Lists paired iPhones and lets the user revoke them.
struct PairedDevicesWindow: View {
    let session: HostSession
    @State private var pendingRevoke: PairedDevice?
    @State private var errorMessage: String?
    @State private var isConfirmingReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if session.pairedDevices.isEmpty {
                Text("No iPhones paired yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List(session.pairedDevices, id: \.fingerprint) { device in
                    row(for: device)
                }
            }
            if let issue = session.pairedDevicesIssue {
                VStack(alignment: .leading, spacing: 6) {
                    Text(issue).font(.callout).foregroundStyle(.orange)
                    Button("Reset Paired iPhones…", role: .destructive) { isConfirmingReset = true }
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(minWidth: 360, minHeight: 240)
        .onAppear { session.refreshPairedDevices() }
        .confirmationDialog("Reset the paired iPhones list?", isPresented: $isConfirmingReset, titleVisibility: .visible) {
            Button("Reset and Forget All iPhones", role: .destructive) { resetList() }
        } message: {
            Text("The damaged list is erased. Every iPhone must pair again.")
        }
        .confirmationDialog(
            "Revoke this iPhone?",
            isPresented: isConfirmingRevoke,
            titleVisibility: .visible,
            presenting: pendingRevoke
        ) { device in
            Button("Revoke \(device.name)", role: .destructive) { revoke(device) }
        } message: { device in
            Text("\(device.name) will be disconnected and must pair again to reconnect.")
        }
    }

    private func resetList() {
        do {
            try session.resetPairedDevices()
            session.refreshPairedDevices()
            errorMessage = nil
        } catch {
            errorMessage = "Could not reset the list: \(Self.describe(error))."
        }
    }

    private func row(for device: PairedDevice) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.name)
                        .font(.headline)
                    if device.fingerprint == session.connectedDeviceFingerprint {
                        Text("Connected")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.green.opacity(0.2), in: Capsule())
                    }
                }
                Text("Paired \(device.pairedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Key \(device.fingerprint.verificationCode)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Revoke", role: .destructive) { pendingRevoke = device }
        }
    }

    private var isConfirmingRevoke: Binding<Bool> {
        Binding(
            get: { pendingRevoke != nil },
            set: { if !$0 { pendingRevoke = nil } }
        )
    }

    private func revoke(_ device: PairedDevice) {
        pendingRevoke = nil
        do {
            try session.revoke(device)
            errorMessage = nil
        } catch {
            errorMessage = "Could not revoke \(device.name): \(Self.describe(error)). Try again."
        }
    }

    private static func describe(_ error: PeerStoreError) -> String {
        switch error {
        case .keyStore:
            "the Keychain refused the change"
        case .corrupted:
            "the stored list was damaged"
        case .encodingFailed:
            "the updated list could not be saved"
        case .tooManyPeers:
            "too many paired devices"
        }
    }
}
