import Foundation
import RemoteCore
import Testing
@testable import iOSClient

@MainActor
struct KeyboardControllerTests {
    private final class Recorder {
        var events: [InputEvent] = []
    }

    private func makeController() -> (KeyboardController, ModifierState, Recorder) {
        let recorder = Recorder()
        let modifiers = ModifierState()
        let controller = KeyboardController(modifiers: modifiers) { recorder.events.append($0) }
        return (controller, modifiers, recorder)
    }

    @Test func plainTextIsSentAsText() {
        let (keyboard, _, recorder) = makeController()

        keyboard.insert("héllo")

        #expect(recorder.events == [.text("héllo")])
    }

    @Test func newlineAndTabBecomeNamedKeyPresses() {
        let (keyboard, _, recorder) = makeController()

        keyboard.insert("\n")
        keyboard.insert("\t")

        #expect(recorder.events == [
            .key(.returnKey, isDown: true, modifiers: []),
            .key(.returnKey, isDown: false, modifiers: []),
            .key(.tab, isDown: true, modifiers: []),
            .key(.tab, isDown: false, modifiers: [])
        ])
    }

    @Test func deleteBackwardPressesDelete() {
        let (keyboard, _, recorder) = makeController()

        keyboard.deleteBackward()

        #expect(recorder.events == [
            .key(.delete, isDown: true, modifiers: []),
            .key(.delete, isDown: false, modifiers: [])
        ])
    }

    @Test func latchedCommandTurnsALetterIntoAShortcutThenClears() {
        let (keyboard, modifiers, recorder) = makeController()
        modifiers.toggle(.command)

        keyboard.insert("C")
        keyboard.insert("x")

        #expect(recorder.events == [.shortcut("c", modifiers: [.command]), .text("x")])
        #expect(modifiers.latched.isEmpty)
    }

    @Test func latchedModifiersApplyToNamedKeys() {
        let (keyboard, modifiers, recorder) = makeController()
        modifiers.toggle(.option)

        keyboard.press(.arrowLeft)

        #expect(recorder.events == [
            .key(.arrowLeft, isDown: true, modifiers: [.option]),
            .key(.arrowLeft, isDown: false, modifiers: [.option])
        ])
        #expect(modifiers.latched.isEmpty)
    }

    @Test func longTextIsSplitIntoChunksWithinTheProtocolLimit() {
        let (keyboard, _, recorder) = makeController()
        let text = String(repeating: "a", count: InputEventCoding.maxTextLength * 2 + 10)

        keyboard.insert(text)

        #expect(recorder.events.count == 3)
        let joined = recorder.events.compactMap { event -> String? in
            if case .text(let chunk) = event { return chunk }
            return nil
        }.joined()
        #expect(joined == text)
        #expect(recorder.events.allSatisfy { event in
            if case .text(let chunk) = event { return chunk.count <= InputEventCoding.maxTextLength }
            return false
        })
    }

    @Test func togglingTwiceUnlatchesAModifier() {
        let modifiers = ModifierState()

        modifiers.toggle(.shift)
        modifiers.toggle(.shift)

        #expect(modifiers.latched.isEmpty)
    }
}
