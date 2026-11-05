import Foundation
import OSLog
import VideoToolbox

/// Creates and configures a low-latency H.264 `VTCompressionSession`.
///
/// Profile: High (AutoLevel). With frame reordering disabled this is effectively
/// Constrained High: it keeps High's 8x8 transform and better entropy coding, which
/// noticeably sharpens text and UI edges at a given bitrate, and every target iPhone
/// (A14+) decodes it in hardware. Main would only matter for much older decoders.
enum CompressionSessionFactory {
    struct Result {
        let session: VTCompressionSession
        let isHardwareAccelerated: Bool
    }

    /// Tried in order: hardware low-latency rate control, then any encoder VideoToolbox offers.
    private static var encoderSpecifications: [(name: String, requiresHardware: Bool, spec: [CFString: Any])] { [
        ("hardware low-latency", true, [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
        ]),
        ("default (hardware preferred)", false, [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
        ]),
    ] }

    static func make(
        width: Int,
        height: Int,
        settings: H264EncoderSettings,
        logger: Logger
    ) throws(H264EncoderError) -> Result {
        let (session, requiresHardware) = try createSession(width: width, height: height, logger: logger)
        do throws(H264EncoderError) {
            try configure(session, settings: settings, logger: logger)
            let status = VTCompressionSessionPrepareToEncodeFrames(session)
            guard status == noErr else { throw .prepareFailed(status) }
        } catch {
            VTCompressionSessionInvalidate(session)
            throw error
        }
        // The low-latency encoder does not report UsingHardwareAcceleratedVideoEncoder,
        // but a session created with RequireHardware... is hardware by definition.
        let isHardware = requiresHardware || usesHardware(session)
        if !isHardware {
            logger.warning("H.264 hardware encoder unavailable; using software encoder")
        }
        return Result(session: session, isHardwareAccelerated: isHardware)
    }

    private static func createSession(
        width: Int,
        height: Int,
        logger: Logger
    ) throws(H264EncoderError) -> (session: VTCompressionSession, requiresHardware: Bool) {
        var lastStatus: OSStatus = noErr
        for candidate in encoderSpecifications {
            var session: VTCompressionSession?
            lastStatus = VTCompressionSessionCreate(
                allocator: nil, width: Int32(width), height: Int32(height),
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: candidate.spec as CFDictionary,
                imageBufferAttributes: nil, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil, compressionSessionOut: &session
            )
            if lastStatus == noErr, let session {
                logger.info("Created H.264 encoder (\(candidate.name, privacy: .public)) \(width)x\(height)")
                return (session, candidate.requiresHardware)
            }
            logger.notice("Encoder spec \(candidate.name, privacy: .public) unavailable (\(lastStatus))")
        }
        throw .sessionCreationFailed(lastStatus)
    }

    private static func configure(
        _ session: VTCompressionSession,
        settings: H264EncoderSettings,
        logger: Logger
    ) throws(H264EncoderError) {
        let keyframeFrames = Int((Double(settings.framesPerSecond) * settings.keyframeIntervalSeconds).rounded())
        let required: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_AverageBitRate, settings.averageBitRate as CFNumber),
        ]
        let optional: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel),
            (kVTCompressionPropertyKey_ExpectedFrameRate, settings.framesPerSecond as CFNumber),
            (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, settings.keyframeIntervalSeconds as CFNumber),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, keyframeFrames as CFNumber),
            (kVTCompressionPropertyKey_DataRateLimits, [settings.peakBytesPerSecond, 1] as CFArray),
            (kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue),
        ]
        for (key, value) in required {
            let status = VTSessionSetProperty(session, key: key, value: value)
            guard status == noErr else { throw .propertyFailed(key: key as String, status: status) }
        }
        for (key, value) in optional {
            let status = VTSessionSetProperty(session, key: key, value: value)
            if status != noErr {
                logger.notice("Encoder ignored \(key as String, privacy: .public) (\(status))")
            }
        }
    }

    private static func usesHardware(_ session: VTCompressionSession) -> Bool {
        var value: CFTypeRef?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            VTSessionCopyProperty(
                session,
                key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                allocator: nil,
                valueOut: pointer
            )
        }
        return status == noErr && (value as? Bool) == true
    }
}
