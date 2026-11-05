import Foundation

/// One sample of what the viewer is receiving. `roundTripMilliseconds` is nil until the first ping returns.
struct StreamStats: Equatable, Sendable {
    static let empty = StreamStats(framesPerSecond: 0, megabitsPerSecond: 0, roundTripMilliseconds: nil)

    let framesPerSecond: Double
    let megabitsPerSecond: Double
    let roundTripMilliseconds: Double?

    /// Compact text for the overlay, e.g. "30 fps · 5.8 Mbps · 12 ms".
    var summary: String {
        "\(framesText) fps · \(rateText) Mbps · \(roundTripText) ms"
    }

    /// Spelled-out text for VoiceOver, e.g. "30 frames per second, 5.8 megabits per second, round trip 12 milliseconds".
    var accessibilitySummary: String {
        let roundTrip = roundTripMilliseconds.map { "\(Int($0.rounded())) milliseconds" } ?? "not measured yet"
        return "\(framesText) frames per second, \(rateText) megabits per second, round trip \(roundTrip)"
    }

    private var framesText: String {
        String(Int(framesPerSecond.rounded()))
    }

    private var rateText: String {
        String(format: "%.1f", megabitsPerSecond)
    }

    private var roundTripText: String {
        roundTripMilliseconds.map { String(Int($0.rounded())) } ?? "–"
    }
}
