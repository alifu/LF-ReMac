import Network
import RemoteCore
import SwiftUI

/// Where a pairing sheet starts: scanning the Mac's QR code, or typing its code for a chosen Mac.
struct PairingRequest: Identifiable, Equatable {
    enum Mode: Equatable { case scan, type }

    let id = UUID()
    var mode: Mode = .scan
    var preselectedHostName: String?
}

struct PairingFlowView: View {
    private static let manualTag = "manual"

    let model: PairingModel
    let discovered: [DiscoveredHost]
    let request: PairingRequest
    let onFinished: () -> Void

    @State private var mode: PairingRequest.Mode
    @State private var selection: String
    @State private var address = ""
    @State private var portText = String(NetworkDefaults.port)
    @State private var codeText = ""

    init(model: PairingModel, discovered: [DiscoveredHost], request: PairingRequest, onFinished: @escaping () -> Void) {
        self.model = model
        self.discovered = discovered
        self.request = request
        self.onFinished = onFinished
        _mode = State(initialValue: request.mode)
        let preferred = discovered.first { $0.name == request.preselectedHostName } ?? discovered.first
        _selection = State(initialValue: preferred?.name ?? Self.manualTag)
    }

    var body: some View {
        NavigationStack {
            Group {
                if case .paired(let hostName) = model.state {
                    successView(hostName)
                } else {
                    pairingContent
                }
            }
            .navigationTitle("Pair a Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onFinished).disabled(model.isWorking)
                }
            }
        }
        .interactiveDismissDisabled(model.isWorking)
    }

    @ViewBuilder
    private var pairingContent: some View {
        if case .confirming(let confirmation) = model.state {
            confirmationView(confirmation)
        } else {
            pickerContent
        }
    }

    private var pickerContent: some View {
        VStack(spacing: 0) {
            Picker("Method", selection: $mode) {
                Text("Scan QR").tag(PairingRequest.Mode.scan)
                Text("Type Code").tag(PairingRequest.Mode.type)
            }
            .pickerStyle(.segmented)
            .padding()
            .onChange(of: mode) { _, _ in model.reset() }

            if mode == .scan {
                scanContent
            } else {
                typeContent
            }
            statusBar
        }
    }

    private var scanContent: some View {
        QRScannerView { text in
            Task { await model.handleScanned(text) }
        }
        .overlay(alignment: .bottom) {
            Text("On your Mac choose “Pair New iPhone…”, then point the camera at the code.")
                .font(.footnote)
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding()
        }
    }

    private var typeContent: some View {
        Form {
            Section("Mac") {
                Picker("Mac", selection: $selection) {
                    ForEach(discovered) { Text($0.name).tag($0.name) }
                    Text("Other address…").tag(Self.manualTag)
                }
                if selection == Self.manualTag {
                    TextField("Host or IP (e.g. 192.168.1.20)", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Port", text: $portText).keyboardType(.numberPad)
                }
            }
            Section("Code shown on the Mac") {
                TextField("ABCD-EFGH-JKMN-PQRS", text: $codeText)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
            }
            Section {
                Button("Pair") { Task { await pairTyped() } }
                    .disabled(model.isWorking || codeText.isEmpty || target == nil)
            }
        }
    }

    @ViewBuilder
    private var statusBar: some View {
        switch model.state {
        case .working:
            ProgressView("Pairing…").padding()
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.footnote)
                .padding()
        case .idle, .paired, .confirming:
            EmptyView()
        }
    }

    private func confirmationView(_ confirmation: PairingConfirmation) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield").font(.system(size: 48)).foregroundStyle(.tint)
            Text("Is this your Mac?").font(.title2.bold())
            Text("Compare this code with the one shown in the Mac's pairing window. Only continue if they are identical.")
                .multilineTextAlignment(.center)
            Text(confirmation.securityCode)
                .font(.system(.title, design: .monospaced).bold())
                .accessibilityLabel("Security code \(confirmation.securityCode)")
            Text("Address in the QR code: \(confirmation.hostLabel)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let warning = confirmation.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding()
                    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack {
                Button("They Differ", role: .cancel) { model.cancelConfirmation() }
                    .buttonStyle(.bordered)
                Button("They Match") { Task { await model.confirmScanned() } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }

    private func successView(_ hostName: String) -> some View {
        ContentUnavailableView {
            Label("Paired with \(hostName)", systemImage: "checkmark.seal.fill")
        } description: {
            Text("Only this iPhone and this Mac can talk to each other now. Remember to turn on “Allow Remote Control” on the Mac if you want to control it.")
        } actions: {
            Button("Done", action: onFinished).buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Helpers

    /// The Mac chosen in the type-code form, or nil if the address fields are incomplete.
    private var target: (endpoint: NWEndpoint, name: String)? {
        if selection != Self.manualTag, let host = discovered.first(where: { $0.name == selection }) {
            return (host.endpoint, host.name)
        }
        guard let endpoint = PairingModel.endpoint(host: address, portText: portText) else { return nil }
        return (endpoint, address.trimmingCharacters(in: .whitespaces))
    }

    private func pairTyped() async {
        guard let target else { return }
        await model.pair(endpoint: target.endpoint, name: target.name, codeText: codeText)
    }
}
