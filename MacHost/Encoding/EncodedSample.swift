import CoreMedia
import Foundation

/// Turns one encoded `CMSampleBuffer` (AVCC) into `EncodedVideoEvent`s.
enum EncodedSample {
    /// Returns `[.config, .frame]` for a keyframe, `[.frame]` otherwise.
    static func events(from sampleBuffer: CMSampleBuffer) throws(H264EncoderError) -> [EncodedVideoEvent] {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw .missingFormatDescription
        }
        let parameters = try AnnexB.parameterSets(from: format)
        let keyframe = isKeyframe(sampleBuffer)
        let frame = EncodedVideoEvent.frame(
            data: try AnnexB.fromAVCC(try avccData(of: sampleBuffer), nalLengthSize: parameters.nalLengthSize),
            isKeyframe: keyframe,
            presentationTimeMicros: EncodedVideoEvent.micros(
                from: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            )
        )
        return keyframe ? [.config(AnnexB.joined(parameters.sets)), frame] : [frame]
    }

    /// A sample is a sync (IDR) frame unless its attachments mark it `NotSync`.
    static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[CFString: Any]],
            let first = attachments.first
        else { return true }
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }

    private static func avccData(of sampleBuffer: CMSampleBuffer) throws(H264EncoderError) -> Data {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { throw .missingBlockBuffer }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: base)
        }
        guard status == noErr else { throw .malformedSampleData }
        return data
    }
}
