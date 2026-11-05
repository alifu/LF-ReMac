import Foundation

/// Errors from pure Annex B / AVCC conversions.
public enum AnnexBError: Error, Equatable, Sendable {
    /// AVCC length prefixes must be 1, 2 or 4 bytes.
    case unsupportedLengthSize(Int)
    /// AVCC data had a truncated length prefix, a zero length, or a length past the end.
    case malformedAVCC
    /// The Annex B stream contained no start code or only empty NAL units.
    case noNALUnits
    /// A NAL unit is too large for a 4-byte length prefix.
    case nalUnitTooLarge(Int)
}

/// H.264 NAL unit type constants (`nal_unit_type`, the low 5 bits of the first NAL byte).
public enum H264NALType {
    public static let idr: UInt8 = 5
    public static let sps: UInt8 = 7
    public static let pps: UInt8 = 8
    static let mask: UInt8 = 0x1F

    /// Returns the `nal_unit_type` of `unit`, or `nil` for an empty unit.
    public static func of(_ unit: Data) -> UInt8? {
        unit.first.map { $0 & mask }
    }
}

/// Pure, platform-neutral helpers for H.264 Annex B byte streams (ITU-T H.264 Annex B)
/// and AVCC (length-prefixed) sample data. No CoreMedia dependency.
///
/// Wire format used by LF-ReMac: every NAL unit is prefixed with `00 00 00 01`; NAL
/// payloads keep their emulation-prevention bytes.
public enum AnnexB {
    /// The 4-byte start code that LF-ReMac writes before every NAL unit.
    public static let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
    /// Length-prefix size used by `toAVCC` (matches `nalUnitHeaderLength: 4`).
    public static let avccLengthSize = 4
    private static let supportedLengthSizes: Set<Int> = [1, 2, 4]

    /// Converts AVCC data (each NAL prefixed by a big-endian length of `nalLengthSize` bytes)
    /// into Annex B (each NAL prefixed by `00 00 00 01`). Empty input yields empty output.
    public static func fromAVCC(_ avcc: Data, nalLengthSize: Int) throws(AnnexBError) -> Data {
        guard supportedLengthSizes.contains(nalLengthSize) else { throw .unsupportedLengthSize(nalLengthSize) }
        let bytes = [UInt8](avcc)
        var output = Data(capacity: bytes.count + startCode.count * 4)
        var offset = 0
        while offset < bytes.count {
            let nalStart = offset + nalLengthSize
            guard nalStart <= bytes.count else { throw .malformedAVCC }
            let length = bytes[offset..<nalStart].reduce(0) { ($0 << 8) | Int($1) }
            let nalEnd = nalStart + length
            guard length > 0, nalEnd <= bytes.count else { throw .malformedAVCC }
            output.append(contentsOf: startCode)
            output.append(contentsOf: bytes[nalStart..<nalEnd])
            offset = nalEnd
        }
        return output
    }

    /// Converts an Annex B stream (3- or 4-byte start codes) into AVCC with 4-byte
    /// big-endian length prefixes, as expected by a format description created with
    /// `nalUnitHeaderLength: 4`.
    /// - Throws: `.noNALUnits` if the stream has no start code or only empty NALs.
    public static func toAVCC(_ annexB: Data) throws(AnnexBError) -> Data {
        let units = nalUnits(in: annexB)
        guard !units.isEmpty else { throw .noNALUnits }
        var output = Data(capacity: annexB.count + units.count * avccLengthSize)
        for unit in units {
            guard let length = UInt32(exactly: unit.count) else { throw .nalUnitTooLarge(unit.count) }
            withUnsafeBytes(of: length.bigEndian) { output.append(contentsOf: $0) }
            output.append(unit)
        }
        return output
    }

    /// Joins raw NAL units (e.g. SPS, PPS) into one Annex B stream with 4-byte start codes.
    public static func joined(_ nalUnits: [Data]) -> Data {
        nalUnits.reduce(into: Data()) { stream, unit in
            stream.append(contentsOf: startCode)
            stream.append(unit)
        }
    }

    /// Splits an Annex B stream into NAL unit payloads (start codes removed).
    ///
    /// Accepts both 3-byte (`00 00 01`) and 4-byte (`00 00 00 01`) start codes. Bytes before
    /// the first start code are ignored, trailing zero bytes of each unit (`trailing_zero_8bits`,
    /// or the leading zero of a following 4-byte start code) are dropped, and empty units are
    /// skipped. Never traps on arbitrary input; garbage without a start code yields `[]`.
    public static func nalUnits(in stream: Data) -> [Data] {
        let bytes = [UInt8](stream)
        let codes = startCodeRanges(in: bytes)
        return codes.indices.compactMap { index in
            let begin = codes[index].upperBound
            let end = index + 1 < codes.count ? codes[index + 1].lowerBound : bytes.count
            let unit = trimmingTrailingZeros(bytes[begin..<end])
            return unit.isEmpty ? nil : Data(unit)
        }
    }

    /// Ranges of every 3-byte `00 00 01` pattern, scanned left to right without overlap.
    private static func startCodeRanges(in bytes: [UInt8]) -> [Range<Int>] {
        let patternLength = 3
        var ranges: [Range<Int>] = []
        var index = 0
        while index + patternLength <= bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                ranges.append(index..<index + patternLength)
                index += patternLength
            } else {
                index += 1
            }
        }
        return ranges
    }

    private static func trimmingTrailingZeros(_ slice: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        guard let lastNonZero = slice.lastIndex(where: { $0 != 0 }) else { return [] }
        return slice[slice.startIndex...lastNonZero]
    }
}
