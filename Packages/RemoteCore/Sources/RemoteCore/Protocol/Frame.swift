import Foundation

/// Kind of message carried by a `Frame`. Raw values are part of the wire format; never reuse one.
public enum MessageType: UInt8, Sendable, CaseIterable {
    case videoConfig = 1      // H.264 parameter sets (SPS/PPS)
    case videoFrame = 2       // One encoded access unit
    case keyframeRequest = 3  // Client asks host for an IDR frame
    case input = 4            // Touch / keyboard event (Phase 3)
    case ping = 5             // Latency probe, payload echoed back
    case pairRequest = 6      // iPhone -> Mac pairing proof (Phase 4)
    case pairResponse = 7     // Mac -> iPhone pairing proof (Phase 4)
    case clientHello = 8      // iPhone -> Mac: protocol version + capabilities (Phase 7)
    case hostInfo = 9         // Mac -> iPhone: displays, wake MACs; only after a hello that asked for it
    case selectDisplay = 10   // iPhone -> Mac: choose which display to stream
}

/// Per-frame flags (bit set).
public struct FrameFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let keyframe = FrameFlags(rawValue: 1 << 0)
}

public enum FrameLimits {
    /// Header: type(1) + flags(1) + timestamp(8) + payload length(4).
    public static let headerBytes = 14
    /// Upper bound that guards against memory exhaustion from a malformed or hostile peer.
    public static let maxPayloadBytes = 16 * 1024 * 1024
}

public enum FrameError: Error, Equatable, Sendable {
    case unknownType(UInt8)
    case payloadTooLarge(Int)
    /// A valid type that this decoder was configured not to accept (e.g. video from an unpaired peer).
    case disallowedType(MessageType)
}

/// One length-prefixed message on the wire. Multi-byte fields are big-endian.
public struct Frame: Equatable, Sendable {
    public let type: MessageType
    public let flags: FrameFlags
    public let timestampMicros: UInt64
    public let payload: Data

    public init(
        type: MessageType,
        flags: FrameFlags = [],
        timestampMicros: UInt64,
        payload: Data
    ) {
        self.type = type
        self.flags = flags
        self.timestampMicros = timestampMicros
        self.payload = payload
    }
}
