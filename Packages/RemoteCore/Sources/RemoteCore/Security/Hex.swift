import Foundation

/// Lowercase hex encoding and strict decoding (used for fingerprints on the wire and in QR payloads).
enum Hex {
    private static let digits = Array("0123456789abcdef".utf8)

    static func encode(_ data: Data) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(data.count * 2)
        for byte in data {
            bytes.append(digits[Int(byte >> 4)])
            bytes.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Accepts upper- or lowercase hex only; returns nil for odd lengths or any other character.
    static func decode(_ string: String) -> Data? {
        let utf8 = Array(string.utf8)
        guard utf8.count.isMultiple(of: 2) else { return nil }
        var result = Data(capacity: utf8.count / 2)
        var index = 0
        while index < utf8.count {
            guard let high = nibble(utf8[index]), let low = nibble(utf8[index + 1]) else { return nil }
            result.append(high << 4 | low)
            index += 2
        }
        return result
    }

    private static func nibble(_ char: UInt8) -> UInt8? {
        switch char {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return char - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return char - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return char - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}
