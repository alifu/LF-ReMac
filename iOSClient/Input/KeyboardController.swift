import Foundation
import Observation
import RemoteCore

/// Modifier keys the user has tapped on the keyboard bar; each applies to the next key, then clears.
@MainActor
@Observable
final class ModifierState {
    private(set) var latched: KeyModifiers = []

    func toggle(_ modifier: KeyModifiers) {
        if latched.contains(modifier) {
            latched.remove(modifier)
        } else {
            latched.insert(modifier)
        }
    }

    /// Returns the latched modifiers and clears them.
    func consume() -> KeyModifiers {
        defer { latched = [] }
        return latched
    }
}

/// Turns on-screen keyboard input into key events.
@MainActor
final class KeyboardController {
    let modifiers: ModifierState
    private let send: @MainActor (InputEvent) -> Void

    init(modifiers: ModifierState, send: @escaping @MainActor (InputEvent) -> Void) {
        self.modifiers = modifiers
        self.send = send
    }

    func insert(_ text: String) {
        switch text {
        case "\n": press(.returnKey)
        case "\t": press(.tab)
        default: type(text)
        }
    }

    func deleteBackward() {
        press(.delete)
    }

    /// Press and release a named key with any latched modifiers.
    func press(_ key: RemoteKey) {
        let held = modifiers.consume()
        send(.key(key, isDown: true, modifiers: held))
        send(.key(key, isDown: false, modifiers: held))
    }

    // MARK: - Helpers

    private func type(_ text: String) {
        let held = modifiers.consume()
        if !held.isEmpty, let shortcut = Self.shortcutCharacter(for: text) {
            send(.shortcut(shortcut, modifiers: held))
            return
        }
        // Modifiers cannot apply to arbitrary Unicode text; they were cleared above.
        for chunk in Self.chunks(of: text, maxLength: InputEventCoding.maxTextLength) {
            send(.text(chunk))
        }
    }

    /// The lowercase letter or digit if `text` is exactly one, else nil (shortcuts are US-layout letters and digits).
    private static func shortcutCharacter(for text: String) -> String? {
        let lowered = text.lowercased()
        guard lowered.count == 1, let scalar = lowered.unicodeScalars.first, scalar.isASCII else { return nil }
        let isLetterOrDigit = ("a"..."z").contains(lowered) || ("0"..."9").contains(lowered)
        return isLetterOrDigit ? lowered : nil
    }

    private static func chunks(of text: String, maxLength: Int) -> [String] {
        var result: [String] = []
        var remaining = Substring(text)
        while !remaining.isEmpty {
            result.append(String(remaining.prefix(maxLength)))
            remaining = remaining.dropFirst(maxLength)
        }
        return result
    }
}
