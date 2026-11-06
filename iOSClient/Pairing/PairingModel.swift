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

/// What the user must check before a scanned QR code is trusted.
struct PairingConfirmation: Equatable {
    /// Address label from the QR code (not verified; shown for context only).
    let hostLabel: String
    /// Short code of the Mac's key; must equal the code shown in the Mac's pairing window.
    let securityCode: String
    /// Set when this looks like a Mac that is already paired.
    let warning: String?
}

/// Drives the pairing screens: validates input, runs the handshake, reports a result for the UI.
@MainActor
@Observable
final class PairingModel {
    enum State: Equatable {
        case idle
        case confirming(PairingConfirmation)
        case working
        case failed(String)
        case paired(hostName: String)
    }

    private(set) var state: State = .idle
    private let service: PairingService
    private let pairedHosts: @MainActor () -> [PairedHost]
    private var pendingInvitation: PairingInvitation?

    init(service: PairingService, pairedHosts: @escaping @MainActor () -> [PairedHost] = { [] }) {
        self.service = service
        self.pairedHosts = pairedHosts
    }

    var isWorking: Bool { state == .working }

    /// QR flow, step 1: nothing is sent to any Mac until the user confirms the Mac's security code.
    /// Ignores repeated scans while a confirmation or pairing attempt is open.
    func handleScanned(_ text: String) async {
        switch state {
        case .working, .confirming: return
        case .idle, .failed, .paired: break
        }
        switch Self.invitation(from: text) {
        case .failure(let error):
            state = .failed(error.userMessage)
        case .success(let invitation):
            pendingInvitation = invitation
            state = .confirming(Self.confirmation(for: invitation, existing: pairedHosts()))
        }
    }

    /// QR flow, step 2: the user confirmed the codes match.
    func confirmScanned() async {
        guard case .confirming = state, let invitation = pendingInvitation else { return }
        pendingInvitation = nil
        await run { () async throws(PhonePairingError) -> PairedHost in try await self.service.pair(with: invitation) }
    }

    func cancelConfirmation() {
        guard case .confirming = state else { return }
        pendingInvitation = nil
        state = .idle
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
        pendingInvitation = nil
        state = .idle
    }

    nonisolated static func invitation(from text: String) -> Result<PairingInvitation, PairingInputError> {
        do {
            return .success(try PairingInvitation(urlString: text.trimmingCharacters(in: .whitespacesAndNewlines)))
        } catch {
            return .failure(.notAnInvitation)
        }
    }

    nonisolated static func confirmation(for invitation: PairingInvitation, existing: [PairedHost]) -> PairingConfirmation {
        PairingConfirmation(
            hostLabel: invitation.host,
            securityCode: invitation.hostFingerprint.verificationCode,
            warning: warning(for: invitation, existing: existing)
        )
    }

    nonisolated private static func warning(for invitation: PairingInvitation, existing: [PairedHost]) -> String? {
        if existing.contains(where: { $0.fingerprint == invitation.hostFingerprint }) {
            return "This Mac is already paired. Pairing again simply refreshes it."
        }
        let label = normalized(invitation.host)
        let looksLikeKnownMac = existing.contains { host in
            normalized(host.name) == label || host.lastKnownHost.map(normalized) == label
        }
        if looksLikeKnownMac {
            return "You already have a Mac with this name, but its security key is DIFFERENT. "
                + "Unless you reinstalled or replaced that Mac, stop: someone may be pretending to be it."
        }
        return nil
    }

    nonisolated private static func normalized(_ name: String) -> String {
        let lowered = name.lowercased()
        return lowered.hasSuffix(".local") ? String(lowered.dropLast(".local".count)) : lowered
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
