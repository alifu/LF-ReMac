import CoreMedia
import Foundation
import OSLog
import RemoteCore
import VideoToolbox

/// Hardware-accelerated, low-latency H.264 encoder (no B-frames, real-time rate control).
///
/// Feed frames with `encode(_:)` from any single thread (typically the capture queue) and
/// consume `events`. See `EncodedVideoEvent` for the exact Annex B byte format.
/// `events` buffers without limit: the consumer must keep up (or drop whole GOPs itself),
/// because silently dropping individual frames would corrupt the decoded stream.
///
/// Thread safety: all mutable state is guarded by `lock`; VideoToolbox delivers output
/// on its own threads and only touches the (thread-safe) stream continuation.
final class H264Encoder: @unchecked Sendable {
    let events: AsyncStream<EncodedVideoEvent>
    let isHardwareAccelerated: Bool

    private let continuation: AsyncStream<EncodedVideoEvent>.Continuation
    private let logger = AppLog.logger(category: "encoder")
    private let lock = NSLock()
    private var session: VTCompressionSession?
    private var isKeyframeRequested = false
    private let settings: H264EncoderSettings

    private static var forceKeyframeProperties: CFDictionary {
        [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
    }

    init(width: Int, height: Int, settings: H264EncoderSettings = .default) throws(H264EncoderError) {
        guard width > 0, height > 0, width.isMultiple(of: 2), height.isMultiple(of: 2) else {
            throw .invalidDimensions(width: width, height: height)
        }
        guard settings.isValid else { throw .invalidSettings }
        let created = try CompressionSessionFactory.make(
            width: width, height: height, settings: settings, logger: logger
        )
        (events, continuation) = AsyncStream.makeStream(of: EncodedVideoEvent.self)
        session = created.session
        self.settings = settings
        isHardwareAccelerated = created.isHardwareAccelerated
    }

    deinit {
        invalidate()
    }

    /// Encodes one captured frame (as delivered by `ScreenCapturer`).
    func encode(_ sampleBuffer: CMSampleBuffer) throws(H264EncoderError) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw .missingImageBuffer
        }
        try encode(
            pixelBuffer: pixelBuffer,
            presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            duration: CMSampleBufferGetDuration(sampleBuffer)
        )
    }

    func encode(
        pixelBuffer: CVPixelBuffer,
        presentationTime: CMTime,
        duration: CMTime = .invalid
    ) throws(H264EncoderError) {
        let (session, shouldForceKeyframe) = takeEncodeState()
        guard let session else { throw .invalidated }
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: duration,
            frameProperties: shouldForceKeyframe ? Self.forceKeyframeProperties : nil,
            infoFlagsOut: nil
        ) { [continuation, logger] status, _, sampleBuffer in
            Self.handleOutput(status: status, sampleBuffer: sampleBuffer, continuation: continuation, logger: logger)
        }
        guard status == noErr else {
            if shouldForceKeyframe { forceKeyframe() }
            throw .encodeFailed(status)
        }
    }

    /// Makes the next encoded frame an IDR (preceded by `.config`). Call when a client
    /// connects or requests a keyframe.
    func forceKeyframe() {
        lock.withLock { isKeyframeRequested = true }
    }

    /// Changes the target bitrate of the live session (average rate and the matching peak cap,
    /// like `CompressionSessionFactory`). Takes effect on following frames; no keyframe needed.
    func setBitrate(_ bitsPerSecond: Int) throws(H264EncoderError) {
        guard bitsPerSecond > 0 else { throw .invalidSettings }
        let target = settings.with(averageBitRate: bitsPerSecond)
        lock.lock()
        defer { lock.unlock() }
        guard let session else { throw .invalidated }
        let average = VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_AverageBitRate, value: target.averageBitRate as CFNumber
        )
        guard average == noErr else {
            throw .propertyFailed(key: kVTCompressionPropertyKey_AverageBitRate as String, status: average)
        }
        // Optional, as in the factory: some encoders ignore the peak cap.
        let limits = VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_DataRateLimits,
            value: [target.peakBytesPerSecond, 1] as CFArray
        )
        if limits != noErr { logger.notice("Encoder ignored DataRateLimits update (\(limits))") }
    }

    /// Blocks until every frame submitted so far has been emitted on `events`.
    func flush() {
        guard let session = lock.withLock({ session }) else { return }
        let status = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        if status != noErr {
            logger.error("Flushing encoder failed (\(status))")
        }
    }

    /// Stops the encoder and finishes `events`. Frames still in flight are discarded;
    /// call `flush()` first to keep them. Safe to call more than once.
    func invalidate() {
        let session = lock.withLock {
            defer { self.session = nil }
            return self.session
        }
        guard let session else { return }
        VTCompressionSessionInvalidate(session)
        continuation.finish()
        logger.info("Encoder invalidated")
    }

    private func takeEncodeState() -> (VTCompressionSession?, Bool) {
        lock.withLock {
            defer { isKeyframeRequested = false }
            return (session, isKeyframeRequested)
        }
    }

    // MARK: - Output (runs on a VideoToolbox thread)

    private static func handleOutput(
        status: OSStatus,
        sampleBuffer: CMSampleBuffer?,
        continuation: AsyncStream<EncodedVideoEvent>.Continuation,
        logger: Logger
    ) {
        guard status == noErr else {
            logger.error("Encoder output error (\(status))")
            return
        }
        guard let sampleBuffer else { return } // Frame was dropped by the encoder.
        do {
            for event in try EncodedSample.events(from: sampleBuffer) {
                continuation.yield(event)
            }
        } catch {
            logger.error("Dropping encoded frame: \(error.localizedDescription, privacy: .public)")
        }
    }
}
