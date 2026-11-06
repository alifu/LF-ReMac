import Foundation

/// Which message types each side accepts from a paired peer. Anything else is a protocol error,
/// so a peer can never make the other side parse a message it has no business sending.
public enum ProtocolTypes {
    /// What the Mac accepts from its paired iPhone.
    public static let hostAcceptsFromPairedClient: Set<MessageType> = [
        .keyframeRequest, .input, .ping, .clientHello, .selectDisplay,
    ]

    /// What the iPhone accepts from the Mac.
    public static let clientAcceptsFromHost: Set<MessageType> = [
        .videoConfig, .videoFrame, .ping, .pairResponse, .hostInfo,
    ]
}

/// What a connected iPhone said it can handle. A Mac sends a Phase 7 message only if the iPhone
/// asked for it, so an older iPhone build (which never says hello) keeps working: it would
/// otherwise drop the link on the first message type it does not know.
public struct PeerCapabilities: Equatable, Sendable {
    public let capabilities: Set<Capability>

    /// A peer that has not (or never will) send a hello.
    public static let legacy = PeerCapabilities(capabilities: [])

    public init(capabilities: Set<Capability>) {
        self.capabilities = capabilities
    }

    public init(hello: ClientHello) {
        self.init(capabilities: hello.capabilities)
    }

    /// Whether the Mac may send a frame of this type to the peer.
    public func canReceive(_ type: MessageType) -> Bool {
        switch type {
        case .videoConfig, .videoFrame, .ping, .pairResponse:
            true
        case .hostInfo:
            capabilities.contains(.displays)
        case .keyframeRequest, .input, .pairRequest, .clientHello, .selectDisplay:
            false
        }
    }
}
