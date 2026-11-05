import CoreMedia
import Foundation

/// Errors from `SampleBufferFactory`. Malformed network input always surfaces as one of these.
public enum SampleBufferFactoryError: Error, LocalizedError, Equatable, Sendable {
    /// A frame arrived before any valid `videoConfig`.
    case noFormatDescription
    /// The config did not contain at least one SPS and one PPS.
    case invalidConfig
    /// The frame had no start code or no NAL units.
    case malformedFrame
    /// A CoreMedia call failed with this status.
    case coreMediaFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .noFormatDescription: "Video frame arrived before the stream configuration."
        case .invalidConfig: "Video stream configuration is invalid."
        case .malformedFrame: "Video frame data is malformed."
        case .coreMediaFailed(let status): "Preparing a video frame failed (error \(status))."
        }
    }
}

/// Turns LF-ReMac Annex B video payloads into `CMSampleBuffer`s for
/// `AVSampleBufferDisplayLayer` (which decodes in hardware; no `VTDecompressionSession`).
///
/// Value type with **mutating** state: `ingestConfig` updates the stored format description
/// in place; `makeSampleBuffer` is non-mutating. Copies are independent. Not shared across
/// isolation domains in practice: keep one instance per stream inside the owning actor.
///
/// Usage: call `ingestConfig` for every `MessageType.videoConfig`, then `makeSampleBuffer`
/// for every `MessageType.videoFrame` (passing `FrameFlags.keyframe`).
public struct SampleBufferFactory: Sendable {
    private static let timescale: CMTimeScale = 1_000_000

    /// Current H.264 format description (nil until the first valid config).
    public private(set) var formatDescription: CMVideoFormatDescription?
    /// Parameter sets (SPS first, then PPS) behind `formatDescription`.
    private var parameterSets: [Data] = []

    public init() {}

    /// Builds a format description from an Annex B config (`00 00 00 01 <SPS> 00 00 00 01 <PPS>`).
    ///
    /// Byte-identical parameter sets keep the existing format description so the display
    /// layer does not reset its decoder.
    /// - Returns: `true` if the format description was replaced (e.g. resolution change).
    /// - Throws: `.invalidConfig` without SPS+PPS, `.coreMediaFailed` if CoreMedia rejects them.
    ///   On failure the previous format description is kept.
    @discardableResult
    public mutating func ingestConfig(_ annexB: Data) throws(SampleBufferFactoryError) -> Bool {
        let units = AnnexB.nalUnits(in: annexB)
        let sps = units.filter { H264NALType.of($0) == H264NALType.sps }
        let pps = units.filter { H264NALType.of($0) == H264NALType.pps }
        guard !sps.isEmpty, !pps.isEmpty else { throw .invalidConfig }
        let sets = sps + pps
        if sets == parameterSets, formatDescription != nil { return false }
        formatDescription = try Self.makeFormatDescription(parameterSets: sets)
        parameterSets = sets
        return true
    }

    /// Wraps one Annex B access unit in a ready `CMSampleBuffer` (AVCC, 4-byte lengths).
    ///
    /// Attachments: `DisplayImmediately = true` (live, no timestamp pacing) and
    /// `NotSync = !isKeyframe`. Timing: PTS = DTS = `presentationTimeMicros` µs, duration invalid.
    public func makeSampleBuffer(
        annexB: Data,
        presentationTimeMicros: UInt64,
        isKeyframe: Bool
    ) throws(SampleBufferFactoryError) -> CMSampleBuffer {
        guard let formatDescription else { throw .noFormatDescription }
        let avcc: Data
        do { avcc = try AnnexB.toAVCC(annexB) } catch { throw .malformedFrame }
        let blockBuffer = try Self.makeBlockBuffer(copying: avcc)
        let pts = CMTime(value: CMTimeValue(clamping: presentationTimeMicros), timescale: Self.timescale)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: pts)
        var sampleSize = avcc.count
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: formatDescription,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { throw .coreMediaFailed(status) }
        try Self.setAttachments(on: sampleBuffer, isKeyframe: isKeyframe)
        return sampleBuffer
    }

    // MARK: - CoreMedia helpers

    private static func makeFormatDescription(
        parameterSets: [Data]
    ) throws(SampleBufferFactoryError) -> CMVideoFormatDescription {
        let joined = [UInt8](parameterSets.reduce(into: Data()) { $0.append($1) })
        let sizes = parameterSets.map(\.count)
        let offsets = sizes.reduce(into: [0]) { $0.append($0[$0.count - 1] + $1) }.dropLast()
        var format: CMFormatDescription?
        let status = joined.withUnsafeBufferPointer { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return kCMFormatDescriptionError_InvalidParameter }
            let pointers = offsets.map { base + $0 }
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: parameterSets.count,
                parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: Int32(AnnexB.avccLengthSize), formatDescriptionOut: &format
            )
        }
        guard status == noErr, let format else { throw .coreMediaFailed(status) }
        return format
    }

    /// Allocates a block buffer that owns a copy of `data`, so its lifetime is independent of `data`.
    private static func makeBlockBuffer(copying data: Data) throws(SampleBufferFactoryError) -> CMBlockBuffer {
        var blockBuffer: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &blockBuffer
        )
        guard createStatus == noErr, let blockBuffer else { throw .coreMediaFailed(createStatus) }
        let copyStatus = data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(
                with: base, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: data.count
            )
        }
        guard copyStatus == noErr else { throw .coreMediaFailed(copyStatus) }
        return blockBuffer
    }

    private static func setAttachments(
        on sampleBuffer: CMSampleBuffer,
        isKeyframe: Bool
    ) throws(SampleBufferFactoryError) {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
            CFArrayGetCount(attachments) > 0,
            let rawDictionary = CFArrayGetValueAtIndex(attachments, 0)
        else { throw .coreMediaFailed(kCMSampleBufferError_RequiredParameterMissing) }
        let dictionary = unsafeBitCast(rawDictionary, to: CFMutableDictionary.self)
        set(kCMSampleAttachmentKey_DisplayImmediately, to: true, in: dictionary)
        set(kCMSampleAttachmentKey_NotSync, to: !isKeyframe, in: dictionary)
    }

    private static func set(_ key: CFString, to value: Bool, in dictionary: CFMutableDictionary) {
        let boolean: CFBoolean = value ? kCFBooleanTrue : kCFBooleanFalse
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(key).toOpaque(),
            Unmanaged.passUnretained(boolean).toOpaque()
        )
    }
}
