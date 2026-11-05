import Dispatch

/// Monotonic time in microseconds, used for ping timestamps (immune to wall-clock changes).
enum MonotonicClock {
    private static let nanosecondsPerMicrosecond: UInt64 = 1_000
    private static let microsecondsPerMillisecond = 1_000.0

    static func nowMicros() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / nanosecondsPerMicrosecond
    }

    /// Elapsed milliseconds between a send and a receive timestamp; nil if the timestamps are out of order.
    static func roundTripMilliseconds(sentMicros: UInt64, receivedMicros: UInt64) -> Double? {
        guard receivedMicros >= sentMicros else { return nil }
        return Double(receivedMicros - sentMicros) / microsecondsPerMillisecond
    }
}
