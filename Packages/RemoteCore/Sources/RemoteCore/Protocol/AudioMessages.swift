import Foundation

public enum AudioCodec: String, Codable, Sendable {
    case aacLC = "aac-lc"
}

/// Mac -> iPhone, sent before the first audio frame and whenever the format changes.
public struct AudioConfig: Codable, Equatable, Sendable {
    public let codec: AudioCodec
    public let sampleRate: Int
    public let channels: Int
    /// PCM samples per channel in one access unit (1024 for AAC-LC).
    public let frameSamples: Int
    /// The codec's setup bytes (for AAC, the AudioSpecificConfig), needed to build the decoder.
    public let audioSpecificConfig: Data

    public init(codec: AudioCodec, sampleRate: Int, channels: Int, frameSamples: Int, audioSpecificConfig: Data) {
        self.codec = codec
        self.sampleRate = sampleRate
        self.channels = channels
        self.frameSamples = frameSamples
        self.audioSpecificConfig = audioSpecificConfig
    }

    public var frameDurationMilliseconds: Double {
        Double(frameSamples) * 1000 / Double(sampleRate)
    }
}

/// iPhone -> Mac: audio costs bandwidth and CPU, so the Mac captures it only while this is on.
public struct AudioControl: Codable, Equatable, Sendable {
    public let enabled: Bool

    public init(enabled: Bool) {
        self.enabled = enabled
    }
}

/// How much audio the iPhone keeps queued before playing, and when it drops audio instead of letting
/// the delay grow. Video is shown the moment it arrives, so audio must stay shallow to remain in sync.
/// Pure state machine: the player reports how much is queued and applies the returned action.
public struct AudioJitterPolicy: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Queue the frame but do not start playing yet.
        case hold
        /// Queue the frame and start playing.
        case start
        /// Queue the frame; already playing.
        case play
        /// Too much is queued: discard the queued audio, then queue this frame and keep playing.
        case catchUp
    }

    public static let defaultStartMilliseconds = 40.0
    public static let defaultMaxMilliseconds = 120.0

    public let startMilliseconds: Double
    public let maxMilliseconds: Double
    public private(set) var isPlaying = false

    /// `start` is kept below `max` so playback can always begin.
    public init(startMilliseconds: Double = defaultStartMilliseconds, maxMilliseconds: Double = defaultMaxMilliseconds) {
        let maxValue = max(maxMilliseconds, 2)
        self.maxMilliseconds = maxValue
        self.startMilliseconds = min(max(startMilliseconds, 0), maxValue / 2)
    }

    /// - Parameters:
    ///   - frameMilliseconds: length of the arriving frame.
    ///   - bufferedMilliseconds: audio already queued and not yet played.
    public mutating func ingest(frameMilliseconds: Double, bufferedMilliseconds: Double) -> Action {
        let total = bufferedMilliseconds + frameMilliseconds
        guard isPlaying else {
            if total >= startMilliseconds {
                isPlaying = true
                return .start
            }
            return .hold
        }
        return total > maxMilliseconds ? .catchUp : .play
    }

    /// The queue ran dry: wait for a little audio again before resuming, instead of stuttering.
    public mutating func underrun() {
        isPlaying = false
    }

    public mutating func reset() {
        isPlaying = false
    }
}
