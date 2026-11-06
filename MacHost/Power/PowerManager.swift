import Foundation
import IOKit.pwr_mgt

/// Holds a "prevent idle system sleep" assertion so the Mac stays reachable while hosting.
/// The display may still sleep; only the system is kept awake.
final class PowerManager {
    /// Creates an assertion and returns a way to release it, or nil if the system refused.
    typealias Acquire = @Sendable (_ reason: String) -> (@Sendable () -> Void)?

    static let reason = "LF-ReMac is hosting a remote session"

    private let acquire: Acquire
    private var release: (() -> Void)?

    init(acquire: @escaping Acquire = PowerManager.systemAcquire) {
        self.acquire = acquire
    }

    deinit { release?() }

    var isHoldingAssertion: Bool { release != nil }

    /// Returns whether the assertion is held afterwards. Safe to call repeatedly.
    @discardableResult
    func setKeepAwake(_ enabled: Bool) -> Bool {
        if enabled {
            if release == nil { release = acquire(Self.reason) }
        } else {
            release?()
            release = nil
        }
        return isHoldingAssertion
    }

    static let systemAcquire: Acquire = { reason in
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        guard result == kIOReturnSuccess else { return nil }
        let assertionID = id
        return { IOPMAssertionRelease(assertionID) }
    }
}
