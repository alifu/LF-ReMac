import CoreMedia
import Foundation
import RemoteCore

/// MacHost-facing Annex B helpers. Byte-level conversions delegate to the shared
/// `RemoteCore.AnnexB` (also used by the iOS client); this wrapper keeps the encoder's
/// `H264EncoderError` contract and adds the CoreMedia parameter-set extraction.
enum AnnexB {
    static let startCode: [UInt8] = RemoteCore.AnnexB.startCode

    /// Converts AVCC data (each NAL prefixed by a big-endian length of `nalLengthSize` bytes)
    /// into Annex B (each NAL prefixed by `00 00 00 01`).
    static func fromAVCC(_ avcc: Data, nalLengthSize: Int) throws(H264EncoderError) -> Data {
        do {
            return try RemoteCore.AnnexB.fromAVCC(avcc, nalLengthSize: nalLengthSize)
        } catch {
            throw .malformedSampleData
        }
    }

    /// Joins raw NAL units (e.g. SPS, PPS) into one Annex B stream.
    static func joined(_ nalUnits: [Data]) -> Data {
        RemoteCore.AnnexB.joined(nalUnits)
    }

    /// Splits an Annex B stream back into NAL units (3- or 4-byte start codes).
    /// Inverse of `joined`; intended for tests and diagnostics.
    static func nalUnits(in stream: Data) -> [Data] {
        RemoteCore.AnnexB.nalUnits(in: stream)
    }

    /// Reads all H.264 parameter sets (SPS first, then PPS) and the AVCC NAL length size.
    static func parameterSets(
        from format: CMFormatDescription
    ) throws(H264EncoderError) -> (sets: [Data], nalLengthSize: Int) {
        var count = 0
        var nalLengthSize: Int32 = 0
        let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLengthSize
        )
        guard status == noErr, count > 0 else { throw .parameterSetUnavailable(status) }
        let sets = try (0..<count).map { index throws(H264EncoderError) in
            try parameterSet(at: index, in: format)
        }
        return (sets, Int(nalLengthSize))
    }

    private static func parameterSet(
        at index: Int,
        in format: CMFormatDescription
    ) throws(H264EncoderError) -> Data {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
            parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
        )
        guard status == noErr, let pointer, size > 0 else { throw .parameterSetUnavailable(status) }
        return Data(bytes: pointer, count: size)
    }
}
