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
    /// AAC-LC at 96 kbps is about 280 bytes per frame; this leaves plenty of room for loud peaks.
    public static let maxAudioFrameBytes = 8 * 1024
    public static let maxAudioSetupBytes = 64
    public static let audioSampleRates: Set<Int> = [44_100, 48_000]
    public static let audioFrameSizes: Set<Int> = [960, 1024]

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

    public static func frame(for config: AudioConfig, timestampMicros: UInt64) throws(SessionMessageError) -> Frame {
        Frame(type: .audioConfig, timestampMicros: timestampMicros, payload: try encode(config))
    }

    public static func frame(for control: AudioControl, timestampMicros: UInt64) throws(SessionMessageError) -> Frame {
        Frame(type: .audioControl, timestampMicros: timestampMicros, payload: try encode(control))
    }

    /// The payload of an audio frame is the raw access unit, not JSON.
    public static func audioFrame(aac: Data, timestampMicros: UInt64) throws(SessionMessageError) -> Frame {
        guard !aac.isEmpty else { throw .invalidField }
        guard aac.count <= maxAudioFrameBytes else { throw .payloadTooLarge(aac.count) }
        return Frame(type: .audioFrame, timestampMicros: timestampMicros, payload: aac)
    }

    // MARK: Decoding

    public static func audioConfig(from frame: Frame) throws(SessionMessageError) -> AudioConfig {
        let config: AudioConfig = try decode(frame, expecting: .audioConfig, maxBytes: maxSmallMessageBytes)
        guard audioSampleRates.contains(config.sampleRate),
              (1...2).contains(config.channels),
              audioFrameSizes.contains(config.frameSamples),
              (1...maxAudioSetupBytes).contains(config.audioSpecificConfig.count)
        else { throw .invalidField }
        return config
    }

    public static func audioControl(from frame: Frame) throws(SessionMessageError) -> AudioControl {
        try decode(frame, expecting: .audioControl, maxBytes: maxSmallMessageBytes)
    }

    public static func audioAccessUnit(from frame: Frame) throws(SessionMessageError) -> Data {
        guard frame.type == .audioFrame else { throw .wrongMessageType }
        guard frame.payload.count <= maxAudioFrameBytes else { throw .payloadTooLarge(frame.payload.count) }
        guard !frame.payload.isEmpty else { throw .invalidField }
        return frame.payload
    }

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
        // The wire form is colon-separated; MACAddress also rejects all-zero and broadcast addresses.
        value.contains(":") && MACAddress(value) != nil
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
