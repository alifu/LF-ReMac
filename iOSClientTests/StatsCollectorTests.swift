import Foundation
import Testing
@testable import iOSClient

struct StatsCollectorTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func computesFramesPerSecondAndMegabitsPerSecondOverInterval() {
        let collector = StatsCollector(startedAt: start)
        for _ in 0..<60 { collector.recordRenderedFrame() }
        collector.recordBytes(1_500_000)

        let stats = collector.snapshot(now: start.addingTimeInterval(2))

        #expect(stats.framesPerSecond == 30)
        #expect(stats.megabitsPerSecond == 6.0)
    }

    @Test func reportsNoRoundTripBeforeAnyPing() {
        let collector = StatsCollector(startedAt: start)

        let stats = collector.snapshot(now: start.addingTimeInterval(1))

        #expect(stats.roundTripMilliseconds == nil)
    }

    @Test func resetsCountersAfterSnapshot() {
        let collector = StatsCollector(startedAt: start)
        for _ in 0..<60 { collector.recordRenderedFrame() }
        collector.recordBytes(1_500_000)
        _ = collector.snapshot(now: start.addingTimeInterval(2))

        let next = collector.snapshot(now: start.addingTimeInterval(4))

        #expect(next.framesPerSecond == 0)
        #expect(next.megabitsPerSecond == 0)
    }

    @Test func returnsLatestRoundTripAndKeepsItAcrossSnapshots() {
        let collector = StatsCollector(startedAt: start)
        collector.recordRoundTrip(milliseconds: 12)
        collector.recordRoundTrip(milliseconds: 30)

        let first = collector.snapshot(now: start.addingTimeInterval(1))
        let second = collector.snapshot(now: start.addingTimeInterval(2))

        #expect(first.roundTripMilliseconds == 30)
        #expect(second.roundTripMilliseconds == 30)
    }

    @Test func zeroIntervalReturnsPreviousStatsWithoutDiscardingCounters() {
        let collector = StatsCollector(startedAt: start)
        for _ in 0..<60 { collector.recordRenderedFrame() }
        let previous = collector.snapshot(now: start.addingTimeInterval(2))
        for _ in 0..<60 { collector.recordRenderedFrame() }

        let sameInstant = collector.snapshot(now: start.addingTimeInterval(2))
        let later = collector.snapshot(now: start.addingTimeInterval(4))

        #expect(sameInstant == previous)
        #expect(later.framesPerSecond == 30)
    }

    @Test func negativeIntervalReturnsPreviousStats() {
        let collector = StatsCollector(startedAt: start)
        let previous = collector.snapshot(now: start.addingTimeInterval(2))

        let earlier = collector.snapshot(now: start.addingTimeInterval(1))

        #expect(earlier == previous)
    }

    @Test func resetClearsCountersAndRoundTrip() {
        let collector = StatsCollector(startedAt: start)
        for _ in 0..<60 { collector.recordRenderedFrame() }
        collector.recordRoundTrip(milliseconds: 12)

        collector.reset(startedAt: start)
        let stats = collector.snapshot(now: start.addingTimeInterval(2))

        #expect(stats == .empty)
    }
}

struct StreamStatsTests {
    @Test func summaryFormatsRatesAndRoundTrip() {
        let stats = StreamStats(framesPerSecond: 29.6, megabitsPerSecond: 5.84, roundTripMilliseconds: 11.7)

        #expect(stats.summary == "30 fps · 5.8 Mbps · 12 ms")
    }

    @Test func summaryShowsDashWhenRoundTripIsUnknown() {
        let stats = StreamStats(framesPerSecond: 30, megabitsPerSecond: 5.8, roundTripMilliseconds: nil)

        #expect(stats.summary == "30 fps · 5.8 Mbps · – ms")
    }

    @Test func accessibilitySummarySpellsOutNumbers() {
        let stats = StreamStats(framesPerSecond: 30, megabitsPerSecond: 5.8, roundTripMilliseconds: 12)

        #expect(stats.accessibilitySummary == "30 frames per second, 5.8 megabits per second, round trip 12 milliseconds")
    }
}

struct MonotonicClockTests {
    @Test func roundTripIsElapsedMilliseconds() {
        let milliseconds = MonotonicClock.roundTripMilliseconds(sentMicros: 1_000, receivedMicros: 13_500)

        #expect(milliseconds == 12.5)
    }

    @Test func roundTripIsNilWhenTimestampsAreOutOfOrder() {
        let milliseconds = MonotonicClock.roundTripMilliseconds(sentMicros: 2_000, receivedMicros: 1_000)

        #expect(milliseconds == nil)
    }
}
