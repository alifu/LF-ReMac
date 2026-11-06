import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import MacHost

struct H264EncoderTests {
    private static let width = 640
    private static let height = 480
    private static let frameCount = 30
    private static let forcedKeyframeIndex = 20
    private static let startCode = Data([0x00, 0x00, 0x00, 0x01])
    private static let nalTypeMask: UInt8 = 0x1F
    private static let spsType: UInt8 = 7
    private static let ppsType: UInt8 = 8

    @Test func rejectsInvalidDimensions() {
        #expect(throws: H264EncoderError.invalidDimensions(width: 0, height: 480)) {
            try H264Encoder(width: 0, height: 480)
        }
    }

    @Test func encodesSyntheticFramesAsAnnexB() async throws {
        let encoder = try H264Encoder(width: Self.width, height: Self.height)
        let events = try await Self.encodeFrames(with: encoder)

        let first = try #require(events.first)
        guard case .config(let config) = first else {
            Issue.record("First event must be .config, got \(first)")
            return
        }
        Self.expectValidParameterSets(config)

        let frames = events.compactMap(Self.frameInfo)
        #expect(frames.count == Self.frameCount)
        #expect(frames.first?.isKeyframe == true)
        #expect(frames.allSatisfy { $0.data.starts(with: Self.startCode) && $0.data.count > Self.startCode.count })
        #expect(frames.map(\.pts) == frames.map(\.pts).sorted())
    }

    @Test func forceKeyframeProducesIDRWithFreshConfig() async throws {
        let encoder = try H264Encoder(width: Self.width, height: Self.height)
        let events = try await Self.encodeFrames(with: encoder, forceKeyframeAt: Self.forcedKeyframeIndex)

        let frames = events.compactMap(Self.frameInfo)
        try #require(frames.count == Self.frameCount)
        #expect(frames[Self.forcedKeyframeIndex].isKeyframe)
        #expect(frames[1..<Self.forcedKeyframeIndex].allSatisfy { !$0.isKeyframe })

        for (index, event) in events.enumerated() {
            guard case .frame(_, true, _) = event else { continue }
            guard index > 0, case .config = events[index - 1] else {
                Issue.record("Keyframe at event \(index) was not preceded by .config")
                continue
            }
        }
    }

    @Test func configRoundTripsThroughFormatDescription() async throws {
        let encoder = try H264Encoder(width: Self.width, height: Self.height)
        let events = try await Self.encodeFrames(with: encoder)
        guard case .config(let config) = try #require(events.first) else {
            Issue.record("Expected .config first")
            return
        }
        let units = AnnexB.nalUnits(in: config)
        let format = try Self.makeFormatDescription(parameterSets: units)

        let extracted = try AnnexB.parameterSets(from: format)

        #expect(extracted.sets == units)
        #expect(extracted.nalLengthSize == 4)
        #expect(CMVideoFormatDescriptionGetDimensions(format).width == Int32(Self.width))
    }

    @Test func encodeAfterInvalidateThrows() throws {
        let encoder = try H264Encoder(width: Self.width, height: Self.height)
        encoder.invalidate()
        let buffer = try Self.makePixelBuffer(index: 0)

        #expect(throws: H264EncoderError.invalidated) {
            try encoder.encode(pixelBuffer: buffer, presentationTime: .zero)
        }
    }

    @Test func setBitrateSucceedsAndEncodingContinues() async throws {
        let encoder = try H264Encoder(width: Self.width, height: Self.height)
        try encoder.setBitrate(2_000_000)
        try encoder.setBitrate(H264EncoderSettings.default.averageBitRate)
        let events = try await Self.encodeFrames(with: encoder)

        #expect(events.compactMap(Self.frameInfo).count == Self.frameCount)
    }

    @Test func setBitrateRejectsNonPositiveValues() throws {
        let encoder = try H264Encoder(width: Self.width, height: Self.height)
        #expect(throws: H264EncoderError.invalidSettings) { try encoder.setBitrate(0) }
    }

    @Test func setBitrateAfterInvalidateThrows() throws {
        let encoder = try H264Encoder(width: Self.width, height: Self.height)
        encoder.invalidate()
        #expect(throws: H264EncoderError.invalidated) { try encoder.setBitrate(2_000_000) }
    }

    // MARK: - Helpers

    private struct FrameInfo {
        let data: Data
        let isKeyframe: Bool
        let pts: UInt64
    }

    private static func frameInfo(_ event: EncodedVideoEvent) -> FrameInfo? {
        guard case .frame(let data, let isKeyframe, let pts) = event else { return nil }
        return FrameInfo(data: data, isKeyframe: isKeyframe, pts: pts)
    }

    private static func expectValidParameterSets(_ config: Data) {
        #expect(config.starts(with: startCode))
        let units = AnnexB.nalUnits(in: config)
        let types = units.compactMap { $0.first.map { $0 & nalTypeMask } }
        #expect(units.count >= 2)
        #expect(units.allSatisfy { !$0.isEmpty })
        #expect(types.first == spsType)
        #expect(types.contains(ppsType))
    }

    private static func encodeFrames(
        with encoder: H264Encoder,
        forceKeyframeAt forcedIndex: Int? = nil
    ) async throws -> [EncodedVideoEvent] {
        let fps = Int32(H264EncoderSettings.default.framesPerSecond)
        for index in 0..<frameCount {
            if index == forcedIndex {
                encoder.flush()
                encoder.forceKeyframe()
            }
            let buffer = try makePixelBuffer(index: index)
            let pts = CMTime(value: CMTimeValue(index), timescale: fps)
            try encoder.encode(pixelBuffer: buffer, presentationTime: pts)
        }
        encoder.flush()
        encoder.invalidate()

        var collected: [EncodedVideoEvent] = []
        for await event in encoder.events {
            collected.append(event)
        }
        return collected
    }

    /// What the iOS client will do: rebuild a format description from `.config` NAL units.
    private static func makeFormatDescription(parameterSets: [Data]) throws -> CMFormatDescription {
        try #require(parameterSets.count == 2)
        let arrays = parameterSets.map { [UInt8]($0) }
        var format: CMFormatDescription?
        let status = arrays[0].withUnsafeBufferPointer { sps in
            arrays[1].withUnsafeBufferPointer { pps -> OSStatus in
                guard let spsBase = sps.baseAddress, let ppsBase = pps.baseAddress else { return kCMFormatDescriptionError_InvalidParameter }
                let pointers = [spsBase, ppsBase]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &format
                )
            }
        }
        return try #require(status == noErr ? format : nil)
    }

    /// NV12 video-range buffer with a moving gradient so successive frames differ.
    private static func makePixelBuffer(index: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &buffer
        )
        let pixelBuffer = try #require(status == kCVReturnSuccess ? buffer : nil)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        fillPlane(pixelBuffer, plane: 0) { x, y in UInt8(truncatingIfNeeded: x + y + index * 4) }
        fillPlane(pixelBuffer, plane: 1) { x, _ in UInt8(truncatingIfNeeded: 128 + x % 32) }
        return pixelBuffer
    }

    private static func fillPlane(
        _ buffer: CVPixelBuffer,
        plane: Int,
        value: (Int, Int) -> UInt8
    ) {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { return }
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
        let rows = CVPixelBufferGetHeightOfPlane(buffer, plane)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<rows {
            for x in 0..<rowBytes {
                bytes[y * rowBytes + x] = value(x, y)
            }
        }
    }
}
