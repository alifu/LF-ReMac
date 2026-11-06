import Foundation

public enum FrameEncoder {
    public static func encode(_ frame: Frame) -> Data {
        var data = Data(capacity: FrameLimits.headerBytes + frame.payload.count)
        data.append(frame.type.rawValue)
        data.append(frame.flags.rawValue)
        data.append(bigEndian: frame.timestampMicros)
        data.append(bigEndian: UInt32(frame.payload.count))
        data.append(frame.payload)
        return data
    }
}

/// Incremental decoder for a byte stream (TCP delivers arbitrary chunk boundaries).
/// After a protocol error the stream cannot be resynchronised, so the decoder stays failed
/// and the caller must drop the connection.
///
/// For untrusted peers, narrow `maxPayloadBytes` and `allowedTypes`: a disallowed type is rejected
/// as soon as its first byte arrives and an oversized length as soon as the header is complete, so
/// such a peer can never make the decoder buffer more than one header plus `maxPayloadBytes`.
public struct FrameDecoder: Sendable {
    public let maxPayloadBytes: Int
    public let allowedTypes: Set<MessageType>
    private var buffer = Data()
    private var failure: FrameError?

    /// - Parameters:
    ///   - maxPayloadBytes: clamped to `0...FrameLimits.maxPayloadBytes`.
    ///   - allowedTypes: every other type is a protocol error.
    public init(
        maxPayloadBytes: Int = FrameLimits.maxPayloadBytes,
        allowedTypes: Set<MessageType> = Set(MessageType.allCases)
    ) {
        self.maxPayloadBytes = min(max(0, maxPayloadBytes), FrameLimits.maxPayloadBytes)
        self.allowedTypes = allowedTypes
    }

    public mutating func append(_ chunk: Data) throws(FrameError) -> [Frame] {
        if let failure { throw failure }
        buffer.append(chunk)

        var frames: [Frame] = []
        do {
            while let frame = try nextFrame() {
                frames.append(frame)
            }
        } catch {
            failure = error
            buffer.removeAll()
            throw error
        }
        return frames
    }

    private mutating func nextFrame() throws(FrameError) -> Frame? {
        guard let first = buffer.first else { return nil }
        let type = try checkedType(first)
        guard buffer.count >= FrameLimits.headerBytes else { return nil }

        let base = buffer.startIndex
        let flags = FrameFlags(rawValue: buffer[base + 1])
        let timestamp: UInt64 = buffer.readBigEndian(at: base + 2)
        let length = Int(buffer.readBigEndian(at: base + 10) as UInt32)
        guard length <= maxPayloadBytes else {
            throw .payloadTooLarge(length)
        }

        let total = FrameLimits.headerBytes + length
        guard buffer.count >= total else { return nil }

        let payload = Data(buffer[(base + FrameLimits.headerBytes)..<(base + total)])
        buffer = Data(buffer.dropFirst(total))
        return Frame(type: type, flags: flags, timestampMicros: timestamp, payload: payload)
    }

    private func checkedType(_ rawType: UInt8) throws(FrameError) -> MessageType {
        guard let type = MessageType(rawValue: rawType) else { throw .unknownType(rawType) }
        guard allowedTypes.contains(type) else { throw .disallowedType(type) }
        return type
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(bigEndian value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    func readBigEndian<T: FixedWidthInteger>(at index: Int) -> T {
        let size = MemoryLayout<T>.size
        let value = self[index..<(index + size)].reduce(T.zero) { ($0 << 8) | T($1) }
        return value
    }
}
