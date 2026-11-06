import Foundation
import Network
import Observation
import RemoteCore

/// Why what the user scanned or typed cannot be used. Nothing has been sent to any Mac yet.
enum PairingInputError: Error, Equatable {
    case notAnInvitation
    case invalidCode
    case invalidAddress

    var userMessage: String {
        switch self {
        case .notAnInvitation: "That is not an LF-ReMac pairing code. Scan the code shown on your Mac."
        case .invalidCode: "That code is not valid. It has 16 letters and digits, like ABCD-EFGH-JKMN-PQRS."
        case .invalidAddress: "Enter the Mac's address and a port between 1 and 65535."
        }
    }
}

/// Drives the pairing screens: validates input, runs the handshake, reports a result for the UI.
@MainActor
@Observable
final class PairingModel {
    enum State: Equatable {
        case idle
        case working
        case failed(String)
        case paired(hostName: String)
    }

    private(set) var state: State = .idle
    private let service: PairingService

    init(service: PairingService) {
        self.service = service
    }

    var isWorking: Bool { state == .working }

    /// QR flow. Ignores repeated scans while a pairing attempt is running.
    func handleScanned(_ text: String) async {
        guard !isWorking else { return }
        switch Self.invitation(from: text) {
        case .failure(let error):
            state = .failed(error.userMessage)
        case .success(let invitation):
            await run { () async throws(PhonePairingError) -> PairedHost in try await self.service.pair(with: invitation) }
        }
    }

    /// Typed-code flow: the user chose a Mac (found by Bonjour or typed in) and entered the code.
    func pair(endpoint: NWEndpoint, name: String, codeText: String) async {
        guard !isWorking else { return }
        guard let code = try? PairingSecret(code: codeText) else {
            state = .failed(PairingInputError.invalidCode.userMessage)
            return
        }
        await run { () async throws(PhonePairingError) -> PairedHost in
            try await self.service.pair(endpoint: endpoint, name: name, code: code)
        }
    }

    func reset() {
        guard !isWorking else { return }
        state = .idle
    }

    nonisolated static func invitation(from text: String) -> Result<PairingInvitation, PairingInputError> {
        do {
            return .success(try PairingInvitation(urlString: text.trimmingCharacters(in: .whitespacesAndNewlines)))
        } catch {
            return .failure(.notAnInvitation)
        }
    }

    nonisolated static func endpoint(host: String, portText: String) -> NWEndpoint? {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let value = UInt16(portText), let port = NWEndpoint.Port(rawValue: value) else {
            return nil
        }
        return .hostPort(host: NWEndpoint.Host(trimmed), port: port)
    }

    private func run(_ pairing: () async throws(PhonePairingError) -> PairedHost) async {
        state = .working
        do {
            let host = try await pairing()
            state = .paired(hostName: host.name)
        } catch {
            state = .failed(error.userMessage)
        }
    }
}
