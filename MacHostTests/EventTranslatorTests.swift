import CoreGraphics
import Foundation
import RemoteCore
import Testing
@testable import MacHost

struct EventTranslatorTests {
    private let bounds = CGRect(x: 100, y: 50, width: 1000, height: 500)

    private func makeTranslator() -> EventTranslator {
        EventTranslator(displayBounds: bounds, source: nil)
    }

    @Test func mapsNormalizedPointIntoDisplayCoordinates() throws {
        var translator = makeTranslator()

        let events = translator.events(for: .pointerMove(NormalizedPoint(x: 0.5, y: 0.25)), now: 0)

        let event = try #require(events.first)
        #expect(event.type == .mouseMoved)
        #expect(event.location == CGPoint(x: 600, y: 175))
    }

    @Test func mapsIntoADisplayLeftOfAndAboveTheMainDisplay() throws {
        var translator = EventTranslator(displayBounds: CGRect(x: -1920, y: -200, width: 1920, height: 1080), source: nil)

        let events = translator.events(for: .pointerMove(NormalizedPoint(x: 0.5, y: 0.5)), now: 0)

        let event = try #require(events.first)
        #expect(event.location == CGPoint(x: -960, y: 340))
    }

    @Test func movesBecomeDragsWhileLeftButtonIsHeld() throws {
        var translator = makeTranslator()
        _ = translator.events(for: .button(.left, isDown: true, at: .center), now: 0)

        let move = try #require(translator.events(for: .pointerMove(.center), now: 0.1).first)

        #expect(move.type == .leftMouseDragged)
    }

    @Test func movesBecomeRightDragsWhileRightButtonIsHeld() throws {
        var translator = makeTranslator()
        _ = translator.events(for: .button(.right, isDown: true, at: .center), now: 0)

        let move = try #require(translator.events(for: .pointerMove(.center), now: 0.1).first)

        #expect(move.type == .rightMouseDragged)
    }

    @Test func movesReturnToPlainMovesAfterRelease() throws {
        var translator = makeTranslator()
        _ = translator.events(for: .button(.left, isDown: true, at: .center), now: 0)
        _ = translator.events(for: .button(.left, isDown: false, at: .center), now: 0.05)

        let move = try #require(translator.events(for: .pointerMove(.center), now: 0.1).first)

        #expect(move.type == .mouseMoved)
    }

    @Test func buttonEventsUseTheMatchingMouseTypes() throws {
        var translator = makeTranslator()

        let leftDown = try #require(translator.events(for: .button(.left, isDown: true, at: .center), now: 0).first)
        let leftUp = try #require(translator.events(for: .button(.left, isDown: false, at: .center), now: 0.01).first)
        let rightDown = try #require(translator.events(for: .button(.right, isDown: true, at: .center), now: 5).first)
        let rightUp = try #require(translator.events(for: .button(.right, isDown: false, at: .center), now: 5.01).first)

        #expect([leftDown.type, leftUp.type, rightDown.type, rightUp.type] == [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp])
    }

    @Test func quickRepeatedClicksCountUpForDoubleClick() throws {
        var translator = makeTranslator()
        var clickStates: [Int64] = []

        for time in [0.0, 0.2] {
            let down = try #require(translator.events(for: .button(.left, isDown: true, at: .center), now: time).first)
            clickStates.append(down.getIntegerValueField(.mouseEventClickState))
            _ = translator.events(for: .button(.left, isDown: false, at: .center), now: time + 0.05)
        }

        #expect(clickStates == [1, 2])
    }

    @Test func slowClicksStartOverAtOne() throws {
        var translator = makeTranslator()
        _ = translator.events(for: .button(.left, isDown: true, at: .center), now: 0)

        let second = try #require(translator.events(for: .button(.left, isDown: true, at: .center), now: 2).first)

        #expect(second.getIntegerValueField(.mouseEventClickState) == 1)
    }

    @Test func scrollUsesPixelUnitsOnBothAxes() throws {
        var translator = makeTranslator()

        let event = try #require(translator.events(for: .scroll(dx: -3.4, dy: 12.6), now: 0).first)

        #expect(event.type == .scrollWheel)
        #expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 13)
        #expect(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == -3)
    }

    @Test func scrollThatRoundsToNothingProducesNoEvent() {
        var translator = makeTranslator()

        #expect(translator.events(for: .scroll(dx: 0.2, dy: -0.4), now: 0).isEmpty)
    }

    @Test func textBecomesDownUpPairPerCharacterCarryingUnicode() throws {
        var translator = makeTranslator()

        let events = translator.events(for: .text("a👋"), now: 0)

        #expect(events.count == 4)
        #expect(events.map(\.type) == [.keyDown, .keyUp, .keyDown, .keyUp])
        #expect(Self.unicode(of: events[0]) == "a")
        #expect(Self.unicode(of: events[2]) == "👋")
    }

    @Test func namedKeysUseMacVirtualKeyCodesAndModifiers() throws {
        var translator = makeTranslator()

        let event = try #require(translator.events(for: .key(.returnKey, isDown: true, modifiers: [.shift, .command]), now: 0).first)

        #expect(event.type == .keyDown)
        #expect(event.getIntegerValueField(.keyboardEventKeycode) == 36)
        #expect(event.flags.contains(.maskShift))
        #expect(event.flags.contains(.maskCommand))
        #expect(!event.flags.contains(.maskControl))
    }

    @Test func shortcutPressesAndReleasesTheLetterKeyWithModifiers() throws {
        var translator = makeTranslator()

        let events = translator.events(for: .shortcut("c", modifiers: [.command]), now: 0)

        #expect(events.map(\.type) == [.keyDown, .keyUp])
        #expect(events.allSatisfy { $0.getIntegerValueField(.keyboardEventKeycode) == 8 })
        #expect(events.allSatisfy { $0.flags.contains(.maskCommand) })
    }

    @Test func releaseAllLiftsAHeldButtonAtMostOnce() {
        var translator = makeTranslator()
        _ = translator.events(for: .button(.left, isDown: true, at: NormalizedPoint(x: 0.1, y: 0.1)), now: 0)

        let first = translator.releaseAll()
        let second = translator.releaseAll()

        #expect(first.map(\.type) == [.leftMouseUp])
        #expect(second.isEmpty)
    }

    @Test func releaseAllLiftsKeysThatAreStillDown() {
        var translator = makeTranslator()
        _ = translator.events(for: .key(.arrowLeft, isDown: true, modifiers: [.shift]), now: 0)

        let released = translator.releaseAll()

        #expect(released.map(\.type) == [.keyUp])
        #expect(released.first?.getIntegerValueField(.keyboardEventKeycode) == 123)
        #expect(translator.releaseAll().isEmpty)
    }

    @Test func releaseAllIgnoresKeysAlreadyReleased() {
        var translator = makeTranslator()
        _ = translator.events(for: .key(.tab, isDown: true, modifiers: []), now: 0)
        _ = translator.events(for: .key(.tab, isDown: false, modifiers: []), now: 0.1)

        #expect(translator.releaseAll().isEmpty)
    }

    private static func unicode(of event: CGEvent) -> String {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &buffer)
        return String(utf16CodeUnits: buffer, count: length)
    }
}
