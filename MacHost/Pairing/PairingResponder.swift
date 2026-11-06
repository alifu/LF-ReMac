import Foundation
import RemoteCore

/// Why a pairing connection ended without pairing. Shown in the UI; never sent to the peer.
enum PairingRejection: Error, Equatable, Sendable {
    /// The pairing session refused the attempt (wrong code, expired, too many attempts, closed).
    case attempt(PairingFailure)
    /// The proof was valid but the device could not be saved (the secret is used up regardless).
    case couldNotSave
    /// The peer did not send a pairing request in time. Does not use up an attempt.
    case timedOut
    /// The peer sent something other than a well-formed `pairRequest`. Does not use up an attempt.
    case malformedRequest
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

    /// Only a well-formed request reaches the pairing session, so only a wrong proof (or the
    /// window's own state) can count against the attempt budget; junk is just rejected.
    /// - Parameter clientFingerprint: the peer's key as observed in the TLS handshake.
    func respond(to frame: Frame, from clientFingerprint: DeviceFingerprint) -> Outcome {
        guard let request = try? PairingMessageCoding.request(from: frame) else {
            return .rejected(.malformedRequest)
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
