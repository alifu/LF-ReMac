import Foundation

/// Resource limits for connections that are not (yet) the authorized session.
///
/// Per-address caps keep one LAN host from using up the global ones, so a paired iPhone on another
/// address can always connect; the short timeouts make held slots cheap to recover.
struct StreamServerLimits: Sendable {
    /// A TLS 1.3 handshake on a LAN or Tailscale link takes well under a second.
    static let standardHandshakeTimeout: TimeInterval = 3
    /// The iPhone sends its `pairRequest` immediately after the handshake.
    static let standardPairRequestTimeout: TimeInterval = 5

    /// TCP/TLS handshakes in progress at once; more are cancelled on arrival.
    let maxHandshaking: Int
    /// Handshakes in progress from one remote address.
    let maxHandshakingPerAddress: Int
    /// Unpaired connections allowed while the pairing window is open.
    let maxPairingConnections: Int
    /// Unpaired (pairing-role) connections from one remote address.
    let maxPairingConnectionsPerAddress: Int
    /// A connection must finish the TLS handshake within this time.
    let handshakeTimeout: TimeInterval
    /// An unpaired connection must send its `pairRequest` within this time.
    let pairRequestTimeout: TimeInterval
    /// How long a paired-and-answered pairing connection may linger so the reply can drain.
    let pairingLinger: TimeInterval

    static let standard = StreamServerLimits(
        maxHandshaking: 32,
        maxHandshakingPerAddress: 2,
        maxPairingConnections: 4,
        maxPairingConnectionsPerAddress: 1,
        handshakeTimeout: standardHandshakeTimeout,
        pairRequestTimeout: standardPairRequestTimeout,
        pairingLinger: 2
    )
}

/// Whether a new TCP connection may start its TLS handshake. Pure so the policy is unit-testable.
enum HandshakeAdmission: Equatable, Sendable {
    case admitted
    case tooManyInTotal
    case tooManyFromAddress

    /// - Parameter inProgress: remote addresses of the handshakes currently in progress.
    static func decide(for address: ConnectionSource, inProgress: [ConnectionSource], limits: StreamServerLimits) -> Self {
        guard inProgress.count < limits.maxHandshaking else { return .tooManyInTotal }
        let fromAddress = inProgress.filter { $0 == address }.count
        guard fromAddress < limits.maxHandshakingPerAddress else { return .tooManyFromAddress }
        return .admitted
    }
}
