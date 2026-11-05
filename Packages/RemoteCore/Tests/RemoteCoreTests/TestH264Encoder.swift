import CoreMedia
import CoreVideo
import Foundation
import Testing
import VideoToolbox
@testable import RemoteCore

/// Real VideoToolbox H.264 encoder used only by tests, producing LF-ReMac wire payloads.
enum TestH264Encoder {
    struct EncodedFrame: Sendable {
        let annexB: Data
        let isKeyframe: Bool
        let presentationTimeMicros: UInt64
    }

    struct Output: Sendable {
        /// Annex B config (`00 00 00 01 <SPS> 00 00 00 01 <PPS>`) from the first keyframe.
        let config: Data
        let frames: [EncodedFrame]
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [CMSampleBuffer] = []
        private var failures: [OSStatus] = []

        func record(status: OSStatus, sample: CMSampleBuffer?) {
            lock.withLock {
                if status == noErr, let sample { samples.append(sample) } else { failures.append(status) }
            }
        }

        var result: (samples: [CMSampleBuffer], failures: [OSStatus]) {
            lock.withLock { (samples, failures) }
        }
    }

    private static let fps: Int32 = 30

    /// Encodes `frameCount` synthetic NV12 frames (real-time, no reordering).
    static func encode(width: Int, height: Int, frameCount: Int = 10) throws -> Output {
        let session = try makeSession(width: width, height: height)
        defer { VTCompressionSessionInvalidate(session) }
        let collector = Collector()
        for index in 0..<frameCount {
            let buffer = try makePixelBuffer(width: width, height: height, index: index)
            let status = VTCompressionSessionEncodeFrame(
                session, imageBuffer: buffer,
                presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: fps),
                duration: .invalid, frameProperties: nil, infoFlagsOut: nil
            ) { status, _, sample in collector.record(status: status, sample: sample) }
            try #require(status == noErr)
        }
        try #require(VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid) == noErr)
        let (samples, failures) = collector.result
        try #require(failures.isEmpty && samples.count == frameCount)
        let first = try #require(samples.first)
        return Output(config: try config(of: first), frames: try samples.map(frame(from:)))
    }

    private static func makeSession(width: Int, height: Int) throws -> VTCompressionSession {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session
        )
        let created = try #require(status == noErr ? session : nil)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTCompressionSessionPrepareToEncodeFrames(created)
        return created
    }

    private static func config(of sample: CMSampleBuffer) throws -> Data {
        let format = try #require(CMSampleBufferGetFormatDescription(sample))
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil
        )
        let sets = try (0..<count).map { index -> Data in
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            )
            let base = try #require(status == noErr ? pointer : nil)
            return Data(bytes: base, count: size)
        }
        return AnnexB.joined(sets)
    }

    private static func frame(from sample: CMSampleBuffer) throws -> EncodedFrame {
        let block = try #require(CMSampleBufferGetDataBuffer(sample))
        let length = CMBlockBufferGetDataLength(block)
        var avcc = Data(count: length)
        let status = avcc.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        try #require(status == noErr)
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let pts = CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sample), timescale: 1_000_000, method: .default)
        return EncodedFrame(
            annexB: try AnnexB.fromAVCC(avcc, nalLengthSize: 4),
            isKeyframe: !notSync,
            presentationTimeMicros: UInt64(max(pts.value, 0))
        )
    }

    /// NV12 buffer with a moving gradient so successive frames differ.
    private static func makePixelBuffer(width: Int, height: Int, index: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &buffer
        )
        let pixelBuffer = try #require(status == kCVReturnSuccess ? buffer : nil)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else { continue }
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
            let rows = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<rows {
                for x in 0..<rowBytes {
                    bytes[y * rowBytes + x] = plane == 0 ? UInt8(truncatingIfNeeded: x + y + index * 4) : 128
                }
            }
        }
        return pixelBuffer
    }
}
