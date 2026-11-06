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
    }

    /// About 270 ms of video at 30 fps.
    static let defaultMaxPendingFrames = 8

    private let maxPendingFrames: Int
    private var isWaitingForKeyframe = true
    private var hasSeenConfig = false
    private(set) var pendingSends = 0

    init(maxPendingFrames: Int = Self.defaultMaxPendingFrames) {
        self.maxPendingFrames = maxPendingFrames
    }

    mutating func decide(for frame: Frame) -> Decision {
        switch frame.type {
        case .videoConfig, .videoFrame:
            return decideVideo(frame)
        case .keyframeRequest, .input, .ping, .pairRequest, .pairResponse:
            return enqueue()
        }
    }

    /// Call when the network layer has taken ownership of a frame that was approved with `.send`.
    mutating func sendCompleted() {
        pendingSends = max(0, pendingSends - 1)
    }

    private mutating func decideVideo(_ frame: Frame) -> Decision {
        if pendingSends >= maxPendingFrames {
            let wasStreaming = !isWaitingForKeyframe
            isWaitingForKeyframe = true
            hasSeenConfig = false
            return wasStreaming ? .dropAndRequestKeyframe : .drop
        }
        guard isWaitingForKeyframe else { return enqueue() }

        if frame.type == .videoConfig {
            hasSeenConfig = true
            return enqueue()
        }
        if frame.flags.contains(.keyframe), hasSeenConfig {
            isWaitingForKeyframe = false
            return enqueue()
        }
        return .drop
    }

    private mutating func enqueue() -> Decision {
        pendingSends += 1
        return .send
    }
}
