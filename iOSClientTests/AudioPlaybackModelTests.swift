import RemoteCore
import Testing
@testable import iOSClient

struct AudioPlaybackModelTests {
    private let frameMs = 21.0

    @Test func holdsUntilEnoughIsQueuedThenStarts() {
        var model = AudioPlaybackModel()

        #expect(model.ingest(frameMilliseconds: frameMs).action == .hold)
        #expect(model.ingest(frameMilliseconds: frameMs).action == .start)
    }

    @Test func playedAudioLeavesTheQueue() {
        var model = AudioPlaybackModel()
        let generation = model.ingest(frameMilliseconds: frameMs).generation
        _ = model.ingest(frameMilliseconds: frameMs)

        model.played(milliseconds: frameMs, generation: generation)

        #expect(abs(model.bufferedMilliseconds - frameMs) < 0.001)
    }

    @Test func catchUpEmptiesTheQueueAndKeepsOnlyTheNewestFrame() {
        var model = AudioPlaybackModel()
        var last = model.ingest(frameMilliseconds: frameMs)
        for _ in 0..<4 { last = model.ingest(frameMilliseconds: frameMs) }
        #expect(last.action == .play)

        let result = model.ingest(frameMilliseconds: frameMs)

        #expect(result.action == .catchUp)
        #expect(abs(model.bufferedMilliseconds - frameMs) < 0.001)
    }

    @Test func playbackReportsFromBeforeACatchUpAreIgnored() {
        var model = AudioPlaybackModel()
        let old = model.ingest(frameMilliseconds: frameMs).generation
        for _ in 0..<4 { _ = model.ingest(frameMilliseconds: frameMs) }
        let caughtUp = model.ingest(frameMilliseconds: frameMs)
        #expect(caughtUp.generation != old)
        let before = model.bufferedMilliseconds

        let underrun = model.played(milliseconds: 100, generation: old)

        #expect(!underrun)
        #expect(model.bufferedMilliseconds == before)
    }

    @Test func runningDryReprimesBeforeResuming() {
        var model = AudioPlaybackModel()
        let first = model.ingest(frameMilliseconds: frameMs)
        let second = model.ingest(frameMilliseconds: frameMs)
        #expect(second.action == .start)

        model.played(milliseconds: frameMs, generation: first.generation)
        let underrun = model.played(milliseconds: frameMs, generation: second.generation)

        #expect(underrun)
        #expect(model.ingest(frameMilliseconds: frameMs).action == .hold)
        #expect(model.ingest(frameMilliseconds: frameMs).action == .start)
    }

    @Test func resetForgetsEverything() {
        var model = AudioPlaybackModel()
        _ = model.ingest(frameMilliseconds: frameMs)
        _ = model.ingest(frameMilliseconds: frameMs)

        model.reset()

        #expect(model.bufferedMilliseconds == 0)
        #expect(model.ingest(frameMilliseconds: frameMs).action == .hold)
    }
}
