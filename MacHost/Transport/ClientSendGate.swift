import Foundation
import RemoteCore

/// Decides which outgoing frames reach one client, keeping latency low.
///
/// - A new client (or one that fell behind) must restart at a clean point: video is dropped until a
///   `videoConfig` followed by a keyframe arrives, because delta frames are undecodable without them.
/// - If the connection backs up, stale video is dropped instead of queued, and one keyframe is requested.
///
/// Pure value type with no I/O so the policy can be unit-tested.
struct ClientSendGate: Sendable {
    enum Decision: Equatable, Sendable {
        case send
        case drop
        case dropAndRequestKeyframe
        /// The backlog has drained after an overflow but no usable keyframe came: drop this frame and
        /// ask again. The first request is made while the backlog is still full, so the keyframe it
        /// produces is dropped too; without a second request the picture would freeze until the next
        /// periodic keyframe. Not a new congestion signal.
        case requestKeyframe
    }

    /// About 270 ms of video at 30 fps.
    static let defaultMaxPendingFrames = 8

    /// About 500 ms of audio at 47 frames a second. Audio is tiny, so it is allowed to queue deeper than
    /// video: a short gap is worse than slightly late audio, but a long backlog is stale and is dropped.
    static let defaultMaxPendingAudioFrames = 24

    private let maxPendingFrames: Int
    private var isWaitingForKeyframe = true
    private var hasSeenConfig = false
    private var needsKeyframeRetry = false
    private(set) var pendingVideoSends = 0
    private(set) var pendingAudioSends = 0
    /// Everything handed to the network and not yet taken over by it.
    var pendingSends: Int { pendingVideoSends + pendingAudioSends }

    init(maxPendingFrames: Int = Self.defaultMaxPendingFrames) {
        self.maxPendingFrames = maxPendingFrames
    }

    mutating func decide(for frame: Frame) -> Decision {
        switch frame.type {
        case .videoConfig, .videoFrame:
            return decideVideo(frame)
        case .audioFrame:
            return decideAudio()
        case .keyframeRequest, .input, .ping, .pairRequest, .pairResponse, .clientHello, .hostInfo, .selectDisplay,
             .audioConfig, .audioControl:
            return enqueue()
        }
    }

    /// Call when the network layer has taken ownership of a frame of `type` that was approved with `.send`.
    /// Audio is counted apart from everything else, so an audio backlog cannot make video overflow (and the reverse).
    mutating func sendCompleted(for type: MessageType) {
        if type == .audioFrame {
            pendingAudioSends = max(0, pendingAudioSends - 1)
        } else {
            pendingVideoSends = max(0, pendingVideoSends - 1)
        }
    }

    private mutating func decideAudio() -> Decision {
        guard pendingAudioSends < Self.defaultMaxPendingAudioFrames else { return .drop }
        pendingAudioSends += 1
        return .send
    }

    private mutating func decideVideo(_ frame: Frame) -> Decision {
        if pendingVideoSends >= maxPendingFrames {
            let wasStreaming = !isWaitingForKeyframe
            isWaitingForKeyframe = true
            hasSeenConfig = false
            needsKeyframeRetry = true
            return wasStreaming ? .dropAndRequestKeyframe : .drop
        }
        guard isWaitingForKeyframe else { return enqueue() }

        if frame.type == .videoConfig {
            hasSeenConfig = true
            needsKeyframeRetry = false
            return enqueue()
        }
        if frame.flags.contains(.keyframe), hasSeenConfig {
            isWaitingForKeyframe = false
            return enqueue()
        }
        if needsKeyframeRetry {
            needsKeyframeRetry = false
            return .requestKeyframe
        }
        return .drop
    }

    private mutating func enqueue() -> Decision {
        pendingVideoSends += 1
        return .send
    }
}
