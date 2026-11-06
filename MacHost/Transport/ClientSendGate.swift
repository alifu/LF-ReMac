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
    private(set) var pendingSends = 0

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

    /// Call when the network layer has taken ownership of a frame that was approved with `.send`.
    mutating func sendCompleted() {
        pendingSends = max(0, pendingSends - 1)
    }

    private mutating func decideAudio() -> Decision {
        pendingSends >= Self.defaultMaxPendingAudioFrames ? .drop : enqueue()
    }

    private mutating func decideVideo(_ frame: Frame) -> Decision {
        if pendingSends >= maxPendingFrames {
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
        pendingSends += 1
        return .send
    }
}
