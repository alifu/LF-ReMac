import CoreMedia
import Foundation

/// Pure helpers for converting VideoToolbox AVCC output into H.264 Annex B byte streams.
enum AnnexB {
    static let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
    private static let supportedLengthSizes: Set<Int> = [1, 2, 4]

    /// Converts AVCC data (each NAL prefixed by a big-endian length of `nalLengthSize` bytes)
    /// into Annex B (each NAL prefixed by `00 00 00 01`).
    static func fromAVCC(_ avcc: Data, nalLengthSize: Int) throws(H264EncoderError) -> Data {
        guard supportedLengthSizes.contains(nalLengthSize) else { throw .malformedSampleData }
        let bytes = [UInt8](avcc)
        var output = Data(capacity: bytes.count + startCode.count * 4)
        var offset = 0
        while offset < bytes.count {
            let nalStart = offset + nalLengthSize
            guard nalStart <= bytes.count else { throw .malformedSampleData }
            let length = bytes[offset..<nalStart].reduce(0) { ($0 << 8) | Int($1) }
            let nalEnd = nalStart + length
            guard length > 0, nalEnd <= bytes.count else { throw .malformedSampleData }
            output.append(contentsOf: startCode)
            output.append(contentsOf: bytes[nalStart..<nalEnd])
            offset = nalEnd
        }
        return output
    }

    /// Joins raw NAL units (e.g. SPS, PPS) into one Annex B stream.
    static func joined(_ nalUnits: [Data]) -> Data {
        nalUnits.reduce(into: Data()) { stream, unit in
            stream.append(contentsOf: startCode)
            stream.append(unit)
        }
    }

    /// Splits an Annex B stream that uses 4-byte start codes back into NAL units.
    /// Inverse of `joined`; intended for tests and diagnostics.
    static func nalUnits(in stream: Data) -> [Data] {
        let bytes = [UInt8](stream)
        let starts = stride(from: 0, to: max(bytes.count - startCode.count + 1, 0), by: 1)
            .filter { Array(bytes[$0..<$0 + startCode.count]) == startCode }
        return starts.enumerated().map { index, start in
            let begin = start + startCode.count
            let end = index + 1 < starts.count ? starts[index + 1] : bytes.count
            return Data(bytes[begin..<end])
        }
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
