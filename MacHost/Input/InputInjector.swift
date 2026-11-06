import CoreGraphics
import Foundation
import RemoteCore

/// Replays remote input on this Mac. Needs Accessibility permission; callers check it first.
@MainActor
final class InputInjector {
    private let logger = AppLog.logger(category: "input")
    private var translator: EventTranslator

    init() {
        translator = EventTranslator(
            displayBounds: CGDisplayBounds(CGMainDisplayID()),
            source: CGEventSource(stateID: .hidSystemState)
        )
    }

    func inject(_ event: InputEvent) {
        translator.displayBounds = CGDisplayBounds(CGMainDisplayID())
        post(translator.events(for: event))
    }

    /// Lifts any held mouse button; call when the client leaves or remote control is switched off.
    func releaseAll() {
        post(translator.releaseAll())
    }

    private func post(_ events: [CGEvent]) {
        for event in events {
            event.post(tap: .cghidEventTap)
        }
    }
}
