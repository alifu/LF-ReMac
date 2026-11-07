import Foundation
import IOKit.pwr_mgt

/// Wakes a sleeping display when an iPhone connects and keeps it on while the session lasts,
/// so the capture shows the desktop instead of black frames.
final class DisplayWaker {
    /// Declares user activity, which turns the display on (also from a dark wake). Returns success.
    typealias Wake = @Sendable (_ reason: String) -> Bool
    /// Creates a "prevent display sleep" assertion and returns its release, or nil if refused.
    typealias Hold = @Sendable (_ reason: String) -> (@Sendable () -> Void)?

    static let reason = "LF-ReMac client connected"

    private let wake: Wake
    private let hold: Hold
    private var release: (() -> Void)?

    init(wake: @escaping Wake = DisplayWaker.systemWake, hold: @escaping Hold = DisplayWaker.systemHold) {
        self.wake = wake
        self.hold = hold
    }

    deinit { release?() }

    var isHoldingDisplayOn: Bool { release != nil }

    /// Wakes the display now and keeps it from idling off. Safe to call repeatedly.
    func wakeAndHold() {
        _ = wake(Self.reason)
        if release == nil { release = hold(Self.reason) }
    }

    /// Lets the display sleep normally again.
    func releaseHold() {
        release?()
        release = nil
    }

    static let systemWake: Wake = { reason in
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionDeclareUserActivity(
            reason as CFString, kIOPMUserActiveLocal, &id
        )
        return result == kIOReturnSuccess
    }

    static let systemHold: Hold = { reason in
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        guard result == kIOReturnSuccess else { return nil }
        let assertionID = id
        return { IOPMAssertionRelease(assertionID) }
    }
}
