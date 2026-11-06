import Foundation
import Testing
@testable import RemoteCore

struct InputEventCodingTests {
    private static let sampleEvents: [InputEvent] = [
        .pointerMove(NormalizedPoint(x: 0.25, y: 0.75)),
        .button(.left, isDown: true, at: NormalizedPoint(x: 0.1, y: 0.2)),
        .button(.right, isDown: false, at: NormalizedPoint(x: 1, y: 0)),
        .scroll(dx: -12.5, dy: 40),
        .text("héllo 👋"),
        .key(.returnKey, isDown: true, modifiers: [.command, .shift]),
        .shortcut("c", modifiers: [.command])
    ]

    @Test(arguments: sampleEvents)
    func roundTripsThroughAFrame(event: InputEvent) throws {
        let frame = try InputEventCoding.frame(for: event, timestampMicros: 77)

        let decoded = try InputEventCoding.event(from: frame)

        #expect(frame.type == .input)
        #expect(frame.timestampMicros == 77)
        #expect(decoded == event)
    }

    @Test func rejectsFramesOfOtherTypes() {
        let frame = Frame(type: .ping, timestampMicros: 0, payload: Data())

        #expect(throws: InputEventError.wrongMessageType) {
            try InputEventCoding.event(from: frame)
        }
    }

    @Test func rejectsGarbagePayload() {
        let frame = Frame(type: .input, timestampMicros: 0, payload: Data([0xFF, 0x00, 0x13]))

        #expect(throws: InputEventError.malformedPayload) {
            try InputEventCoding.event(from: frame)
        }
    }

    @Test func rejectsTextLongerThanLimit() throws {
        let long = String(repeating: "a", count: InputEventCoding.maxTextLength + 1)
        let frame = try InputEventCoding.frame(for: .text(long), timestampMicros: 0)

        #expect(throws: InputEventError.textTooLong(InputEventCoding.maxTextLength + 1)) {
            try InputEventCoding.event(from: frame)
        }
    }

    @Test func rejectsEmptyText() throws {
        let frame = try InputEventCoding.frame(for: .text(""), timestampMicros: 0)

        #expect(throws: InputEventError.invalidText) {
            try InputEventCoding.event(from: frame)
        }
    }

    @Test(arguments: ["", "ab", "C", "!", "é"])
    func rejectsShortcutsThatAreNotOneLowercaseLetterOrDigit(character: String) throws {
        let frame = try InputEventCoding.frame(for: .shortcut(character, modifiers: [.command]), timestampMicros: 0)

        #expect(throws: InputEventError.invalidShortcut) {
            try InputEventCoding.event(from: frame)
        }
    }

    @Test func rejectsHugeScrollValues() throws {
        let frame = try InputEventCoding.frame(for: .scroll(dx: 0, dy: 1_000_000), timestampMicros: 0)

        #expect(throws: InputEventError.invalidScroll) {
            try InputEventCoding.event(from: frame)
        }
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func refusesToEncodeNonFiniteScrollValues(value: Double) {
        #expect(throws: InputEventError.malformedPayload) {
            try InputEventCoding.frame(for: .scroll(dx: value, dy: 0), timestampMicros: 0)
        }
    }

    @Test func clampsOutOfRangePointsWhenDecoding() throws {
        let json = #"{"pointerMove":{"_0":{"x":5,"y":-3}}}"#
        let frame = Frame(type: .input, timestampMicros: 0, payload: Data(json.utf8))

        let decoded = try InputEventCoding.event(from: frame)

        #expect(decoded == .pointerMove(NormalizedPoint(x: 1, y: 0)))
    }
}
