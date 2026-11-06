import Foundation

/// Crockford base32 (no I, L, O, U). Decoding is case-insensitive and maps the look-alikes
/// O -> 0 and I/L -> 1; every other character outside the alphabet is rejected.
enum CrockfordBase32 {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8)

    /// Encodes whole 5-byte groups only (callers use 10-byte secrets -> 16 characters).
    static func encode(_ data: Data) -> String? {
        guard data.count.isMultiple(of: 5) else { return nil }
        var output: [UInt8] = []
        var buffer: UInt64 = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | UInt64(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                output.append(alphabet[Int((buffer >> UInt64(bits)) & 0x1F)])
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Decodes a multiple of 8 symbols (no separators) into bytes; nil on any invalid symbol.
    static func decode(_ string: String) -> Data? {
        let symbols = Array(string.utf8)
        guard symbols.count.isMultiple(of: 8) else { return nil }
        var output = Data()
        var buffer: UInt64 = 0
        var bits = 0
        for symbol in symbols {
            guard let value = value(of: symbol) else { return nil }
            buffer = (buffer << 5) | UInt64(value)
            bits += 5
            if bits >= 8 {
                bits -= 8
                output.append(UInt8((buffer >> UInt64(bits)) & 0xFF))
            }
        }
        return output
    }

    private static func value(of symbol: UInt8) -> UInt8? {
        let upper = (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(symbol) ? symbol - 32 : symbol
        switch upper {
        case UInt8(ascii: "O"): return 0
        case UInt8(ascii: "I"), UInt8(ascii: "L"): return 1
        default: return alphabet.firstIndex(of: upper).map(UInt8.init)
        }
    }
}
