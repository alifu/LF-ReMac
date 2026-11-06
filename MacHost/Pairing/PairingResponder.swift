import Foundation
import RemoteCore

/// Why a pairing connection ended without pairing. Shown in the UI; never sent to the peer.
enum PairingRejection: Error, Equatable, Sendable {
    /// The pairing session refused the attempt (wrong code, expired, too many attempts, closed).
    case attempt(PairingFailure)
    /// The proof was valid but the device could not be saved (the secret is used up regardless).
    case couldNotSave
    /// The peer did not send a pairing request in time.
    case timedOut
}

/// Host side of one pairing request: run the attempt, persist the device, build the reply.
/// No I/O besides the store, so it is testable without sockets.
struct PairingResponder: Sendable {
    enum Outcome: Equatable, Sendable {
        case accepted(PairedDevice, response: Frame)
        case rejected(PairingRejection)
    }

    let coordinator: PairingCoordinator
    let store: PairedDeviceStore
    let hostName: String

    /// - Parameter clientFingerprint: the peer's key as observed in the TLS handshake.
    func respond(to frame: Frame, from clientFingerprint: DeviceFingerprint) -> Outcome {
        guard let request = try? PairingMessageCoding.request(from: frame) else {
            return .rejected(.attempt(coordinator.recordFailedAttempt(from: clientFingerprint)))
        }
        let result = coordinator.attempt(
            proof: request.proof, clientFingerprint: clientFingerprint, deviceName: request.deviceName
        )
        switch result {
        case .failure(let failure):
            return .rejected(.attempt(failure))
        case .success(let acceptance):
            return accept(acceptance)
        }
    }

    /// Unusable traffic (wrong type, oversized, undecodable) from an unpaired peer.
    func protocolViolation(from clientFingerprint: DeviceFingerprint) -> PairingRejection {
        .attempt(coordinator.recordFailedAttempt(from: clientFingerprint))
    }

    private func accept(_ acceptance: PairingAcceptance) -> Outcome {
        guard let response = try? PairingExchange.responseFrame(hostName: hostName, hostProof: acceptance.hostProof) else {
            return .rejected(.couldNotSave)
        }
        do {
            try store.add(acceptance.device)
        } catch {
            return .rejected(.couldNotSave)
        }
        return .accepted(acceptance.device, response: response)
    }
}
