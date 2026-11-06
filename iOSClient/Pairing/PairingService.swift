import Foundation
import Network
import RemoteCore

/// Why pairing with a Mac failed, phrased for the pairing UI.
enum PhonePairingError: Error, Equatable, Sendable {
    case identityUnavailable
    case cannotReach
    /// The Mac answering is not the one in the QR code.
    case hostFingerprintMismatch
    /// The Mac closed the connection: wrong or expired code, or its pairing window is not open.
    case codeRejected
    /// The peer could not prove it knows the code: possibly not your Mac.
    case invalidHostProof
    case invalidResponse
    case timedOut
    case couldNotSave

    init(_ error: PairingHandshakeError) {
        switch error {
        case .cannotReach: self = .cannotReach
        case .hostFingerprintMismatch: self = .hostFingerprintMismatch
        case .rejected: self = .codeRejected
        case .invalidHostProof: self = .invalidHostProof
        case .invalidResponse, .invalidDeviceName: self = .invalidResponse
        case .timedOut: self = .timedOut
        }
    }

    var userMessage: String {
        switch self {
        case .identityUnavailable: "This iPhone's security key could not be loaded from the Keychain."
        case .cannotReach: "Cannot reach the Mac. Check that it is hosting and on the same network."
        case .hostFingerprintMismatch: "The Mac that answered is not the one in the QR code. Pairing stopped."
        case .codeRejected: "The Mac refused the code. Check the code, or start pairing again on the Mac."
        case .invalidHostProof: "The Mac could not prove it knows the code. Pairing stopped for your safety."
        case .invalidResponse: "The Mac sent an unexpected reply."
        case .timedOut: "The Mac did not answer in time."
        case .couldNotSave: "Paired, but the Mac could not be saved on this iPhone. Pair again."
        }
    }
}

/// Runs the pairing handshake and, only once the host proof verified, saves the Mac.
@MainActor
final class PairingService {
    typealias Handshake = @Sendable (
        _ endpoint: NWEndpoint, _ identity: DeviceIdentity, _ secret: PairingSecret,
        _ expectedHost: DeviceFingerprint?, _ deviceName: String
    ) async throws(PairingHandshakeError) -> PairingHandshakeResult

    private let credentials: PhoneCredentials
    private let handshake: Handshake
    private let now: @Sendable () -> Date

    init(
        credentials: PhoneCredentials,
        handshake: @escaping Handshake = PairingService.liveHandshake,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.credentials = credentials
        self.handshake = handshake
        self.now = now
    }

    /// QR flow: dial the invitation's address and require the Mac's key to match the QR code.
    func pair(with invitation: PairingInvitation) async throws(PhonePairingError) -> PairedHost {
        guard let port = NWEndpoint.Port(rawValue: invitation.port) else { throw .cannotReach }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(invitation.host), port: port)
        let result = try await run(endpoint, secret: invitation.secret, expectedHost: invitation.hostFingerprint)
        guard result.hostFingerprint == invitation.hostFingerprint else { throw .hostFingerprintMismatch }
        return try save(PairedHost(
            name: result.hostName, fingerprint: result.hostFingerprint, pairedAt: now(),
            lastKnownHost: invitation.host, lastKnownPort: invitation.port
        ))
    }

    /// Manual flow: the Mac's key is not known in advance; the proofs bind both keys to the code.
    func pair(endpoint: NWEndpoint, name: String, code: PairingSecret) async throws(PhonePairingError) -> PairedHost {
        let result = try await run(endpoint, secret: code, expectedHost: nil)
        let storedName = DeviceName.isValid(name) ? name : result.hostName
        return try save(PairedHost(
            name: storedName, fingerprint: result.hostFingerprint, pairedAt: now(),
            lastKnownHost: result.remoteHost, lastKnownPort: result.remotePort
        ))
    }

    nonisolated static let liveHandshake: Handshake = { endpoint, identity, secret, expected, deviceName async throws(PairingHandshakeError) in
        try await PairingHandshake.run(
            endpoint: endpoint, identity: identity, secret: secret, expectedHostFingerprint: expected, deviceName: deviceName
        )
    }

    private func run(
        _ endpoint: NWEndpoint, secret: PairingSecret, expectedHost: DeviceFingerprint?
    ) async throws(PhonePairingError) -> PairingHandshakeResult {
        let identity: DeviceIdentity
        do {
            identity = try credentials.identity()
        } catch {
            throw .identityUnavailable
        }
        do {
            return try await handshake(endpoint, identity, secret, expectedHost, credentials.deviceName)
        } catch {
            throw PhonePairingError(error)
        }
    }

    private func save(_ host: PairedHost) throws(PhonePairingError) -> PairedHost {
        do {
            try credentials.hostStore.add(host)
        } catch {
            throw .couldNotSave
        }
        return host
    }
}
