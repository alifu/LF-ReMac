import CoreGraphics
import Foundation
import RemoteCore

/// Counts consecutive clicks so double and triple clicks work (macOS expects a click count on each event).
struct ClickCounter: Equatable {
    static let maxInterval: TimeInterval = 0.5
    static let maxDistance: CGFloat = 6

    private var count = 0
    private var lastTime: TimeInterval = 0
    private var lastLocation: CGPoint = .zero
    private var lastButton: PointerButton?

    /// Registers a button-down and returns its click count (1 for a fresh click).
    mutating func registerDown(button: PointerButton, at location: CGPoint, time: TimeInterval) -> Int {
        let continues = count > 0
            && button == lastButton
            && time - lastTime <= Self.maxInterval
            && hypot(location.x - lastLocation.x, location.y - lastLocation.y) <= Self.maxDistance
        count = continues ? count + 1 : 1
        lastTime = time
        lastLocation = location
        lastButton = button
        return count
    }

    /// Count to stamp on the matching button-up.
    var currentCount: Int { max(count, 1) }
}
