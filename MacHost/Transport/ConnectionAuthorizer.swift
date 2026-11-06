import Foundation
import RemoteCore

/// What a TLS connection that reached `.ready` may do, decided from the fingerprint the TLS layer
/// verified (never from anything the peer sends). Pure so the policy is unit-testable.
enum ConnectionAuthorization: Equatable, Sendable {
    /// A paired iPhone: may become the active session (video, input, pings).
    case paired(DeviceFingerprint)
    /// An unknown key while the pairing window is open: may send one `pairRequest`, nothing else.
    case pairing(DeviceFingerprint)
    case refused(Refusal)

    enum Refusal: Equatable, Sendable {
        case noPeerCertificate
        case ownFingerprint
        case notPaired
        case tooManyPairingConnections
        /// This remote address already holds its pairing-role connection.
        case tooManyPairingConnectionsFromAddress
    }
}

enum ConnectionAuthorizer {
    static func authorize(
        peer: DeviceFingerprint?,
        hostFingerprint: DeviceFingerprint,
        isPaired: (DeviceFingerprint) -> Bool,
        isPairingOpen: Bool,
        pairingConnections: Int,
        maxPairingConnections: Int,
        pairingConnectionsFromAddress: Int,
        maxPairingConnectionsPerAddress: Int
    ) -> ConnectionAuthorization {
        guard let peer else { return .refused(.noPeerCertificate) }
        guard !peer.constantTimeEquals(hostFingerprint) else { return .refused(.ownFingerprint) }
        if isPaired(peer) { return .paired(peer) }
        guard isPairingOpen else { return .refused(.notPaired) }
        guard pairingConnections < maxPairingConnections else { return .refused(.tooManyPairingConnections) }
        guard pairingConnectionsFromAddress < maxPairingConnectionsPerAddress else {
            return .refused(.tooManyPairingConnectionsFromAddress)
        }
        return .pairing(peer)
    }
}
