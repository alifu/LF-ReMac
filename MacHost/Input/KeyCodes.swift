import CoreGraphics
import RemoteCore

/// macOS virtual key codes (ANSI / US layout) for the keys the iPhone can send.
enum KeyCodes {
    static func code(for key: RemoteKey) -> CGKeyCode {
        switch key {
        case .returnKey: 36
        case .tab: 48
        case .space: 49
        case .delete: 51
        case .escape: 53
        case .forwardDelete: 117
        case .home: 115
        case .end: 119
        case .pageUp: 116
        case .pageDown: 121
        case .arrowLeft: 123
        case .arrowRight: 124
        case .arrowDown: 125
        case .arrowUp: 126
        }
    }

    /// Key code for a lowercase ASCII letter or digit on a US layout; nil for anything else.
    static func code(forCharacter character: String) -> CGKeyCode? {
        characterCodes[character]
    }

    private static let characterCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35,
        "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29
    ]

    static func flags(for modifiers: KeyModifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        return flags
    }
}
