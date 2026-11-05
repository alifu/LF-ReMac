import Foundation

/// Accumulates received bytes, rendered frames and round-trip samples, and turns them into rates on demand.
///
/// Writers run on the link queue and the renderer's queue; `snapshot` runs on the main actor. Every access
/// goes through `lock`, which is why the class can be `@unchecked Sendable`.
final class StatsCollector: @unchecked Sendable {
    private static let bitsPerByte = 8.0
    private static let bitsPerMegabit = 1_000_000.0

    private let lock = NSLock()
    private var byteCount = 0
    private var frameCount = 0
    private var latestRoundTrip: Double?
    private var windowStart: Date
    private var latestStats = StreamStats.empty

    init(startedAt: Date = .now) {
        windowStart = startedAt
    }

    func recordBytes(_ count: Int) {
        lock.withLock { byteCount += count }
    }

    func recordRenderedFrame() {
        lock.withLock { frameCount += 1 }
    }

    func recordRoundTrip(milliseconds: Double) {
        lock.withLock { latestRoundTrip = milliseconds }
    }

    /// Clears all counters and samples, starting a new measurement window at `startedAt`.
    func reset(startedAt: Date = .now) {
        lock.withLock {
            byteCount = 0
            frameCount = 0
            latestRoundTrip = nil
            windowStart = startedAt
            latestStats = .empty
        }
    }

    /// Rates over the window since the previous snapshot, then starts a new window at `now`.
    /// A non-positive window returns the previous stats and leaves the counters untouched.
    func snapshot(now: Date) -> StreamStats {
        lock.withLock {
            let interval = now.timeIntervalSince(windowStart)
            guard interval > 0 else { return latestStats }
            let stats = StreamStats(
                framesPerSecond: Double(frameCount) / interval,
                megabitsPerSecond: Double(byteCount) * Self.bitsPerByte / Self.bitsPerMegabit / interval,
                roundTripMilliseconds: latestRoundTrip
            )
            byteCount = 0
            frameCount = 0
            windowStart = now
            latestStats = stats
            return stats
        }
    }
}
