import RemoteCore

/// Bookkeeping for the audio player: how much audio is queued and what `AudioJitterPolicy` says to do.
/// Pure, so the rules are tested without an audio engine.
///
/// `generation` changes whenever the queue is thrown away; the engine reports playback of discarded
/// audio late, and those reports must not be subtracted from the new queue.
struct AudioPlaybackModel: Equatable {
    private var policy = AudioJitterPolicy()
    private(set) var bufferedMilliseconds = 0.0
    private(set) var generation = 0

    /// Call for each decoded frame. The caller applies `action` and tags the scheduled audio with `generation`.
    mutating func ingest(frameMilliseconds: Double) -> (action: AudioJitterPolicy.Action, generation: Int) {
        let action = policy.ingest(frameMilliseconds: frameMilliseconds, bufferedMilliseconds: bufferedMilliseconds)
        if action == .catchUp {
            bufferedMilliseconds = 0
            generation += 1
        }
        bufferedMilliseconds += frameMilliseconds
        return (action, generation)
    }

    /// Call when queued audio finished playing. Returns true if the queue ran dry (the player should
    /// pause until `ingest` says to start again).
    @discardableResult
    mutating func played(milliseconds: Double, generation reported: Int) -> Bool {
        guard reported == generation else { return false }
        bufferedMilliseconds = max(0, bufferedMilliseconds - milliseconds)
        guard bufferedMilliseconds < 0.001, policy.isPlaying else { return false }
        policy.underrun()
        return true
    }

    mutating func reset() {
        policy.reset()
        bufferedMilliseconds = 0
        generation += 1
    }
}
