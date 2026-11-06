import Foundation

public enum SessionMessageError: Error, Equatable, Sendable {
    case wrongMessageType
    case payloadTooLarge(Int)
    case malformedPayload
    case invalidField
}

/// JSON coding of the Phase 7 messages. Every decode treats the payload as untrusted: type, then size
/// cap, then shape, then field validation.
public enum SessionMessageCoding {
    public static let maxSmallMessageBytes = 1024
    public static let maxHostInfoBytes = 16 * 1024
    public static let maxDisplays = 16
    public static let maxWakeMACs = 4
    public static let maxNameLength = 64
    public static let maxPixelSize = 16_384
    public static let maxProtocolVersion = 100

    // MARK: Frames

    public static func frame(for hello: ClientHello, timestampMicros: UInt64) throws(SessionMessageError) -> Frame {
        Frame(type: .clientHello, timestampMicros: timestampMicros, payload: try encode(hello))
    }

    public static func frame(for info: HostInfo, timestampMicros: UInt64) throws(SessionMessageError) -> Frame {
        Frame(type: .hostInfo, timestampMicros: timestampMicros, payload: try encode(info))
    }

    public static func frame(for selection: SelectDisplay, timestampMicros: UInt64) throws(SessionMessageError) -> Frame {
        Frame(type: .selectDisplay, timestampMicros: timestampMicros, payload: try encode(selection))
    }

    // MARK: Decoding

    public static func clientHello(from frame: Frame) throws(SessionMessageError) -> ClientHello {
        let hello: ClientHello = try decode(frame, expecting: .clientHello, maxBytes: maxSmallMessageBytes)
        guard (1...maxProtocolVersion).contains(hello.protocolVersion) else { throw .invalidField }
        return hello
    }

    public static func hostInfo(from frame: Frame) throws(SessionMessageError) -> HostInfo {
        let info: HostInfo = try decode(frame, expecting: .hostInfo, maxBytes: maxHostInfoBytes)
        try validate(info)
        return info
    }

    public static func selectDisplay(from frame: Frame) throws(SessionMessageError) -> SelectDisplay {
        let selection: SelectDisplay = try decode(frame, expecting: .selectDisplay, maxBytes: maxSmallMessageBytes)
        guard isDisplayID(selection.displayID) else { throw .invalidField }
        return selection
    }

    // MARK: Validation

    private static func validate(_ info: HostInfo) throws(SessionMessageError) {
        guard info.displays.count <= maxDisplays, info.wakeMACs.count <= maxWakeMACs else { throw .invalidField }
        let ids = info.displays.map(\.id)
        guard Set(ids).count == ids.count else { throw .invalidField }
        for display in info.displays {
            guard isDisplayID(display.id),
                  display.name.count <= maxNameLength,
                  (1...maxPixelSize).contains(display.pixelWidth),
                  (1...maxPixelSize).contains(display.pixelHeight)
            else { throw .invalidField }
        }
        if let selected = info.selectedID, !ids.contains(selected) { throw .invalidField }
        guard info.wakeMACs.allSatisfy(isMAC) else { throw .invalidField }
    }

    private static func isDisplayID(_ value: String) -> Bool {
        value.count == 36 && UUID(uuidString: value) != nil
    }

    private static func isMAC(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 6 && parts.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isHexDigit) }
    }

    // MARK: Private

    private static func encode<T: Encodable>(_ message: T) throws(SessionMessageError) -> Data {
        do {
            return try JSONEncoder().encode(message)
        } catch {
            throw .malformedPayload
        }
    }

    private static func decode<T: Decodable>(
        _ frame: Frame, expecting type: MessageType, maxBytes: Int
    ) throws(SessionMessageError) -> T {
        guard frame.type == type else { throw .wrongMessageType }
        guard frame.payload.count <= maxBytes else { throw .payloadTooLarge(frame.payload.count) }
        do {
            return try JSONDecoder().decode(T.self, from: frame.payload)
        } catch {
            throw .malformedPayload
        }
    }
}
