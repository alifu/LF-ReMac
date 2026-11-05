import CoreMedia
import Foundation

/// Output of `H264Encoder`. All byte payloads are **H.264 Annex B**.
///
/// Wire format (consumed by the iOS decoder, task 2.4):
/// - Every NAL unit is prefixed with the 4-byte start code `00 00 00 01`.
///   NAL payloads keep their emulation-prevention bytes, so no escaping is needed.
/// - `.config`: all parameter sets in order, SPS first then PPS:
///   `00 00 00 01 <SPS> 00 00 00 01 <PPS>`. Send as `MessageType.videoConfig`.
/// - `.frame`: exactly one access unit (one picture), possibly several NALs
///   (e.g. SEI + slices): `00 00 00 01 <NAL> [00 00 00 01 <NAL> ...]`.
///   Send as `MessageType.videoFrame`, with `FrameFlags.keyframe` when `isKeyframe`.
///   Frame data never contains SPS/PPS; a decoder must apply the latest `.config` first.
///
/// Ordering guarantee: a `.config` is emitted immediately before every keyframe
/// (including the very first frame), so a late joiner can start from any keyframe.
/// No B-frames are produced, so decode order equals presentation order.
enum EncodedVideoEvent: Sendable, Equatable {
    case config(Data)
    case frame(data: Data, isKeyframe: Bool, presentationTimeMicros: UInt64)

    /// Converts a presentation timestamp to whole microseconds; invalid or negative times map to 0.
    static func micros(from time: CMTime) -> UInt64 {
        guard time.isValid, time.isNumeric else { return 0 }
        let converted = CMTimeConvertScale(time, timescale: 1_000_000, method: .roundHalfAwayFromZero)
        return converted.value > 0 ? UInt64(converted.value) : 0
    }
}

struct H264EncoderSettings: Sendable, Equatable {
    static let `default` = H264EncoderSettings(
        averageBitRate: 6_000_000,
        framesPerSecond: 30,
        keyframeIntervalSeconds: 2,
        peakBitRateRatio: 1.5
    )

    /// Target average bitrate in bits per second.
    let averageBitRate: Int
    let framesPerSecond: Int
    /// Maximum time between IDR frames.
    let keyframeIntervalSeconds: Double
    /// Hard cap per one-second window, as a multiple of `averageBitRate`, to avoid bursts.
    let peakBitRateRatio: Double

    var isValid: Bool {
        averageBitRate > 0 && framesPerSecond > 0 && keyframeIntervalSeconds > 0 && peakBitRateRatio >= 1
    }

    /// Peak bytes allowed in any one-second window (for `kVTCompressionPropertyKey_DataRateLimits`).
    var peakBytesPerSecond: Int {
        Int(Double(averageBitRate) * peakBitRateRatio / 8)
    }
}

enum H264EncoderError: Error, LocalizedError, Equatable {
    case invalidDimensions(width: Int, height: Int)
    case invalidSettings
    case sessionCreationFailed(OSStatus)
    case propertyFailed(key: String, status: OSStatus)
    case prepareFailed(OSStatus)
    case missingImageBuffer
    case encodeFailed(OSStatus)
    case invalidated
    case missingFormatDescription
    case parameterSetUnavailable(OSStatus)
    case missingBlockBuffer
    case malformedSampleData

    var errorDescription: String? {
        switch self {
        case let .invalidDimensions(width, height):
            "Cannot encode video of size \(width)x\(height); width and height must be positive and even."
        case .invalidSettings:
            "Encoder settings are invalid (bitrate, frame rate and keyframe interval must be positive)."
        case .sessionCreationFailed(let status):
            "The video encoder could not be created (error \(status))."
        case let .propertyFailed(key, status):
            "The video encoder rejected setting \(key) (error \(status))."
        case .prepareFailed(let status):
            "The video encoder failed to start (error \(status))."
        case .missingImageBuffer:
            "The captured frame contained no image."
        case .encodeFailed(let status):
            "Encoding a video frame failed (error \(status))."
        case .invalidated:
            "The video encoder has been stopped."
        case .missingFormatDescription:
            "Encoded frame had no format description."
        case .parameterSetUnavailable(let status):
            "Could not read H.264 parameter sets (error \(status))."
        case .missingBlockBuffer:
            "Encoded frame contained no data."
        case .malformedSampleData:
            "Encoded frame data was malformed."
        }
    }
}
