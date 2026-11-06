import Foundation

/// A position on the remote screen: (0,0) top-left, (1,1) bottom-right, independent of resolution.
public struct NormalizedPoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double

    /// Values are clamped to 0...1; NaN becomes 0.
    public init(x: Double, y: Double) {
        self.x = Self.clamp(x)
        self.y = Self.clamp(y)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(x: try container.decode(Double.self, forKey: .x), y: try container.decode(Double.self, forKey: .y))
    }

    public static let center = NormalizedPoint(x: 0.5, y: 0.5)

    private static func clamp(_ value: Double) -> Double {
        value.isNaN ? 0 : min(max(value, 0), 1)
    }

    private enum CodingKeys: String, CodingKey { case x, y }
}

public enum PointerButton: String, Codable, Sendable {
    case left
    case right
}

/// Modifier keys held during a key event. Raw values are part of the wire format.
public struct KeyModifiers: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)
}

/// Non-character keys. The Mac maps these to its own virtual key codes.
public enum RemoteKey: String, Codable, Sendable, CaseIterable {
    case returnKey
    case tab
    case space
    case delete
    case forwardDelete
    case escape
    case arrowLeft
    case arrowRight
    case arrowUp
    case arrowDown
    case home
    case end
    case pageUp
    case pageDown
}

/// One user action on the iPhone, replayed on the Mac. Sent as JSON in a `.input` frame.
public enum InputEvent: Codable, Equatable, Sendable {
    /// Move the pointer to an absolute position (or drag, if a button is down).
    case pointerMove(NormalizedPoint)
    case button(PointerButton, isDown: Bool, at: NormalizedPoint)
    /// Scroll in points; positive `dy` moves content down (natural direction for a finger drag).
    case scroll(dx: Double, dy: Double)
    /// Type literal text (any language, emoji).
    case text(String)
    case key(RemoteKey, isDown: Bool, modifiers: KeyModifiers)
    /// Press and release one lowercase ASCII letter or digit with modifiers, e.g. Command-C.
    /// Resolved through the US layout on the Mac.
    case shortcut(String, modifiers: KeyModifiers)
}
