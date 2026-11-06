import Foundation

/// Formats the time left in the pairing window as `m:ss`.
enum PairingCountdown {
    private static let secondsPerMinute = 60

    /// Partial seconds round up, so the display never shows 0:00 before the window closes.
    static func text(until expiresAt: Date, now: Date) -> String {
        let remaining = expiresAt.timeIntervalSince(now)
        let seconds = max(0, Int(ceil(remaining)))
        let minutes = seconds / secondsPerMinute
        let rest = seconds % secondsPerMinute
        let padding = rest < 10 ? "0" : ""
        return "\(minutes):\(padding)\(rest)"
    }
}
