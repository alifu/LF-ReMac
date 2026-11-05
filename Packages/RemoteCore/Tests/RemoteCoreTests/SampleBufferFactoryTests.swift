import CoreMedia
import Foundation
import Testing
import VideoToolbox
@testable import RemoteCore

struct SampleBufferFactoryTests {
    private static let width = 640
    private static let height = 480

    // MARK: - Happy path (real encoder output)

    @Test func buildsFormatDescriptionWithEncoderDimensions() throws {
        let output = try TestH264Encoder.encode(width: Self.width, height: Self.height)
        var factory = SampleBufferFactory()

        let changed = try factory.ingestConfig(output.config)

        let format = try #require(factory.formatDescription)
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        #expect(changed)
        #expect(dimensions.width == Int32(Self.width))
        #expect(dimensions.height == Int32(Self.height))
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264)
    }

    @Test func makesValidSampleBuffersWithLiveDisplayAttachments() throws {
        let output = try TestH264Encoder.encode(width: Self.width, height: Self.height)
        var factory = SampleBufferFactory()
        try factory.ingestConfig(output.config)

        let buffers = try output.frames.map {
            try factory.makeSampleBuffer(
                annexB: $0.annexB, presentationTimeMicros: $0.presentationTimeMicros, isKeyframe: $0.isKeyframe
            )
        }

        #expect(output.frames.first?.isKeyframe == true)
        for (buffer, frame) in zip(buffers, output.frames) {
            let attachments = try #require(Self.attachments(of: buffer))
            #expect(CMSampleBufferIsValid(buffer))
            #expect(CMSampleBufferDataIsReady(buffer))
            #expect(CMSampleBufferGetNumSamples(buffer) == 1)
            #expect(attachments[kCMSampleAttachmentKey_DisplayImmediately] as? Bool == true)
            #expect(attachments[kCMSampleAttachmentKey_NotSync] as? Bool == !frame.isKeyframe)
            #expect(CMSampleBufferGetPresentationTimeStamp(buffer).convertScale(1_000_000, method: .default).value
                == Int64(frame.presentationTimeMicros))
            #expect(CMSampleBufferGetDecodeTimeStamp(buffer) == CMSampleBufferGetPresentationTimeStamp(buffer))
        }
    }

    @Test func sampleBufferPayloadIsAVCCOfTheFrame() throws {
        let output = try TestH264Encoder.encode(width: Self.width, height: Self.height)
        var factory = SampleBufferFactory()
        try factory.ingestConfig(output.config)
        let frame = try #require(output.frames.first)

        let buffer = try factory.makeSampleBuffer(annexB: frame.annexB, presentationTimeMicros: 0, isKeyframe: true)

        let block = try #require(CMSampleBufferGetDataBuffer(buffer))
        let length = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: length)
        #expect(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes) == noErr)
        #expect(Data(bytes) == (try AnnexB.toAVCC(frame.annexB)))
    }

    @Test func keyframeSampleBufferDecodesWithVideoToolbox() throws {
        let output = try TestH264Encoder.encode(width: Self.width, height: Self.height)
        var factory = SampleBufferFactory()
        try factory.ingestConfig(output.config)
        let frame = try #require(output.frames.first)
        let buffer = try factory.makeSampleBuffer(annexB: frame.annexB, presentationTimeMicros: 0, isKeyframe: true)
        let format = try #require(factory.formatDescription)

        var session: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: format, decoderSpecification: nil,
            imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session
        )
        let decoder = try #require(createStatus == noErr ? session : nil)
        defer { VTDecompressionSessionInvalidate(decoder) }
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            decoder, sampleBuffer: buffer, flags: [], infoFlagsOut: nil
        ) { status, _, image, _, _ in
            #expect(status == noErr)
            #expect(image.map(CVPixelBufferGetWidth) == Self.width)
        }

        #expect(decodeStatus == noErr)
        #expect(VTDecompressionSessionWaitForAsynchronousFrames(decoder) == noErr)
    }

    // MARK: - Config changes

    @Test func identicalConfigKeepsExistingFormatDescription() throws {
        let output = try TestH264Encoder.encode(width: Self.width, height: Self.height, frameCount: 1)
        var factory = SampleBufferFactory()
        try factory.ingestConfig(output.config)
        let original = try #require(factory.formatDescription)

        let changed = try factory.ingestConfig(output.config)

        #expect(!changed)
        #expect(factory.formatDescription === original)
    }

    @Test func changedConfigReplacesFormatDescription() throws {
        let first = try TestH264Encoder.encode(width: Self.width, height: Self.height, frameCount: 1)
        let second = try TestH264Encoder.encode(width: 320, height: 240, frameCount: 1)
        var factory = SampleBufferFactory()
        try factory.ingestConfig(first.config)
        let original = try #require(factory.formatDescription)

        let changed = try factory.ingestConfig(second.config)

        let replaced = try #require(factory.formatDescription)
        #expect(changed)
        #expect(replaced !== original)
        #expect(CMVideoFormatDescriptionGetDimensions(replaced).width == 320)
        #expect(CMVideoFormatDescriptionGetDimensions(replaced).height == 240)
    }

    @Test func invalidConfigThrowsAndKeepsPreviousFormatDescription() throws {
        let output = try TestH264Encoder.encode(width: Self.width, height: Self.height, frameCount: 1)
        var factory = SampleBufferFactory()
        try factory.ingestConfig(output.config)
        let original = try #require(factory.formatDescription)
        let spsOnly = AnnexB.joined(Array(AnnexB.nalUnits(in: output.config).prefix(1)))

        #expect(throws: SampleBufferFactoryError.invalidConfig) { try factory.ingestConfig(spsOnly) }
        #expect(throws: SampleBufferFactoryError.invalidConfig) { try factory.ingestConfig(Data([1, 2, 3])) }
        #expect(factory.formatDescription === original)
    }

    @Test func garbageParameterSetsFailWithoutCrashing() {
        var factory = SampleBufferFactory()
        let garbage = AnnexB.joined([Data([0x67, 0xFF]), Data([0x68])])

        #expect(throws: SampleBufferFactoryError.self) { try factory.ingestConfig(garbage) }
        #expect(factory.formatDescription == nil)
    }

    // MARK: - Malformed frames

    @Test func frameBeforeConfigThrowsNoFormatDescription() {
        let factory = SampleBufferFactory()

        #expect(throws: SampleBufferFactoryError.noFormatDescription) {
            try factory.makeSampleBuffer(annexB: Data(AnnexB.startCode + [0x65, 0x88]), presentationTimeMicros: 0, isKeyframe: true)
        }
    }

    @Test(arguments: [Data(), Data([0x65, 0x88, 0x84, 0x00]), Data(AnnexB.startCode)])
    func malformedFrameThrows(annexB: Data) throws {
        let output = try TestH264Encoder.encode(width: Self.width, height: Self.height, frameCount: 1)
        var factory = SampleBufferFactory()
        try factory.ingestConfig(output.config)

        #expect(throws: SampleBufferFactoryError.malformedFrame) {
            try factory.makeSampleBuffer(annexB: annexB, presentationTimeMicros: 0, isKeyframe: false)
        }
    }

    @Test func hugeTimestampIsClampedInsteadOfTrapping() throws {
        let output = try TestH264Encoder.encode(width: Self.width, height: Self.height, frameCount: 1)
        var factory = SampleBufferFactory()
        try factory.ingestConfig(output.config)
        let frame = try #require(output.frames.first)

        let buffer = try factory.makeSampleBuffer(annexB: frame.annexB, presentationTimeMicros: .max, isKeyframe: true)

        #expect(CMSampleBufferGetPresentationTimeStamp(buffer).value == Int64.max)
    }

    @Test func errorsHaveUserFacingDescriptions() {
        let errors: [SampleBufferFactoryError] = [.noFormatDescription, .invalidConfig, .malformedFrame, .coreMediaFailed(-1)]

        #expect(errors.allSatisfy { $0.errorDescription?.isEmpty == false })
    }

    // MARK: - Helpers

    private static func attachments(of buffer: CMSampleBuffer) -> [CFString: Any]? {
        (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[CFString: Any]])?.first
    }
}
