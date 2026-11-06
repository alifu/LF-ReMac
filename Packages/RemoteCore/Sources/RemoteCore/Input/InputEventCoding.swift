import Foundation

public enum InputEventError: Error, Equatable, Sendable {
    case wrongMessageType
    case malformedPayload
    case textTooLong(Int)
    case invalidText
    case invalidShortcut
    case invalidScroll
}

/// Converts `InputEvent`s to and from wire frames. Decoding treats the payload as untrusted:
/// anything malformed or out of bounds is rejected rather than replayed on the Mac.
public enum InputEventCoding {
    public static let maxTextLength = 256
    public static let maxScrollMagnitude = 10_000.0

    public static func frame(for event: InputEvent, timestampMicros: UInt64) throws(InputEventError) -> Frame {
        let payload: Data
        do {
            payload = try JSONEncoder().encode(event)
        } catch {
            throw .malformedPayload
        }
        return Frame(type: .input, timestampMicros: timestampMicros, payload: payload)
    }

    public static func event(from frame: Frame) throws(InputEventError) -> InputEvent {
        guard frame.type == .input else { throw .wrongMessageType }
        let event: InputEvent
        do {
            event = try JSONDecoder().decode(InputEvent.self, from: frame.payload)
        } catch {
            throw .malformedPayload
        }
        try validate(event)
        return event
    }

    private static func validate(_ event: InputEvent) throws(InputEventError) {
        switch event {
        case .text(let text):
            guard !text.isEmpty else { throw .invalidText }
            guard text.count <= maxTextLength else { throw .textTooLong(text.count) }
        case .shortcut(let character, _):
            guard isLowercaseAsciiLetterOrDigit(character) else { throw .invalidShortcut }
        case .scroll(let dx, let dy):
            guard isValidScroll(dx), isValidScroll(dy) else { throw .invalidScroll }
        case .pointerMove, .button, .key:
            break
        }
    }

    private static func isValidScroll(_ value: Double) -> Bool {
        value.isFinite && abs(value) <= maxScrollMagnitude
    }

    private static func isLowercaseAsciiLetterOrDigit(_ string: String) -> Bool {
        guard string.utf8.count == 1, let byte = string.utf8.first else { return false }
        return (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }
}
