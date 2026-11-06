import CoreGraphics
import Foundation
import RemoteCore

/// Turns `InputEvent`s into `CGEvent`s without posting them, so the mapping can be unit-tested.
/// Keeps the small amount of state macOS needs: which button is held (drags) and click counts.
struct EventTranslator {
    /// Refreshed by the caller before each event so resolution or display changes are picked up.
    var displayBounds: CGRect
    let source: CGEventSource?

    private var heldButton: PointerButton?
    private var lastLocation: CGPoint
    private var clicks = ClickCounter()

    init(displayBounds: CGRect, source: CGEventSource?) {
        self.displayBounds = displayBounds
        self.source = source
        self.lastLocation = CGPoint(x: displayBounds.midX, y: displayBounds.midY)
    }

    mutating func events(for input: InputEvent, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [CGEvent] {
        switch input {
        case .pointerMove(let point):
            return pointerMove(to: point)
        case .button(let button, let isDown, let point):
            return buttonEvent(button, isDown: isDown, at: point, now: now)
        case .scroll(let dx, let dy):
            return scroll(dx: dx, dy: dy)
        case .text(let text):
            return text.flatMap { typed($0) }
        case .key(let key, let isDown, let modifiers):
            return keyEvent(code: KeyCodes.code(for: key), isDown: isDown, modifiers: modifiers).map { [$0] } ?? []
        case .shortcut(let character, let modifiers):
            return shortcut(character, modifiers: modifiers)
        }
    }

    /// Lifts any held button (e.g. when the client disconnects mid-drag) so the Mac is not left clicking.
    mutating func releaseAll() -> [CGEvent] {
        guard let button = heldButton else { return [] }
        heldButton = nil
        let type: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: lastLocation, mouseButton: cgButton(button))
        return event.map { [$0] } ?? []
    }

    // MARK: - Pointer

    private mutating func pointerMove(to point: NormalizedPoint) -> [CGEvent] {
        let location = location(for: point)
        lastLocation = location
        let type: CGEventType
        switch heldButton {
        case .left: type = .leftMouseDragged
        case .right: type = .rightMouseDragged
        case nil: type = .mouseMoved
        }
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location, mouseButton: cgButton(heldButton ?? .left))
        return event.map { [$0] } ?? []
    }

    private mutating func buttonEvent(_ button: PointerButton, isDown: Bool, at point: NormalizedPoint, now: TimeInterval) -> [CGEvent] {
        let location = location(for: point)
        lastLocation = location
        let clickCount = isDown ? clicks.registerDown(button: button, at: location, time: now) : clicks.currentCount
        heldButton = isDown ? button : nil
        let type = mouseType(button, isDown: isDown)
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location, mouseButton: cgButton(button)) else {
            return []
        }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        return [event]
    }

    private func scroll(dx: Double, dy: Double) -> [CGEvent] {
        let vertical = Int32(dy.rounded())
        let horizontal = Int32(dx.rounded())
        guard vertical != 0 || horizontal != 0 else { return [] }
        let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0)
        return event.map { [$0] } ?? []
    }

    // MARK: - Keyboard

    private func typed(_ character: Character) -> [CGEvent] {
        let units = Array(String(character).utf16)
        return [true, false].compactMap { isDown in
            let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown)
            event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            return event
        }
    }

    private func keyEvent(code: CGKeyCode, isDown: Bool, modifiers: KeyModifiers) -> CGEvent? {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: isDown)
        event?.flags = KeyCodes.flags(for: modifiers)
        return event
    }

    private func shortcut(_ character: String, modifiers: KeyModifiers) -> [CGEvent] {
        guard let code = KeyCodes.code(forCharacter: character) else { return [] }
        return [true, false].compactMap { keyEvent(code: code, isDown: $0, modifiers: modifiers) }
    }

    // MARK: - Helpers

    private func location(for point: NormalizedPoint) -> CGPoint {
        CGPoint(
            x: displayBounds.minX + point.x * displayBounds.width,
            y: displayBounds.minY + point.y * displayBounds.height
        )
    }

    private func cgButton(_ button: PointerButton) -> CGMouseButton {
        button == .left ? .left : .right
    }

    private func mouseType(_ button: PointerButton, isDown: Bool) -> CGEventType {
        switch (button, isDown) {
        case (.left, true): .leftMouseDown
        case (.left, false): .leftMouseUp
        case (.right, true): .rightMouseDown
        case (.right, false): .rightMouseUp
        }
    }
}
