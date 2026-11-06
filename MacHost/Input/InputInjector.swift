import CoreGraphics
import Foundation
import RemoteCore

/// Replays remote input on this Mac. Needs Accessibility permission; callers check it first.
@MainActor
final class InputInjector {
    private let logger = AppLog.logger(category: "input")
    private var translator: EventTranslator
    private var displayID: CGDirectDisplayID = CGMainDisplayID()

    init() {
        translator = EventTranslator(
            displayBounds: CGDisplayBounds(CGMainDisplayID()),
            source: CGEventSource(stateID: .hidSystemState)
        )
    }

    /// Maps pointer positions onto this display; nil means the main display.
    func setDisplay(_ id: CGDirectDisplayID?) {
        displayID = id ?? CGMainDisplayID()
    }

    func inject(_ event: InputEvent) {
        let bounds = CGDisplayBounds(displayID)
        // A display that just went away reports an empty rectangle; clicking there would land elsewhere.
        guard !bounds.isEmpty, !bounds.isNull else { return }
        translator.displayBounds = bounds
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
