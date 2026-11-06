import Foundation

/// Minimal ASN.1 DER *encoder* covering exactly what a self-signed X.509 v3 certificate needs.
/// Nothing here parses untrusted input; parsing of peer certificates is left to Security.framework.
enum DER {
    enum Tag: UInt8 {
        case boolean = 0x01
        case integer = 0x02
        case bitString = 0x03
        case octetString = 0x04
        case objectIdentifier = 0x06
        case utf8String = 0x0C
        case utcTime = 0x17
        case generalizedTime = 0x18
        case sequence = 0x30
        case set = 0x31
    }

    static func element(_ tag: UInt8, _ content: Data) -> Data {
        var data = Data([tag])
        data.append(length(content.count))
        data.append(content)
        return data
    }

    static func element(_ tag: Tag, _ content: Data) -> Data {
        element(tag.rawValue, content)
    }

    static func sequence(_ children: [Data]) -> Data {
        element(.sequence, children.reduce(Data(), +))
    }

    static func set(_ children: [Data]) -> Data {
        element(.set, children.reduce(Data(), +))
    }

    /// Context-specific, constructed, explicit tag `[number]`.
    static func explicit(_ number: UInt8, _ content: Data) -> Data {
        element(0xA0 | number, content)
    }

    static func boolean(_ value: Bool) -> Data {
        element(.boolean, Data([value ? 0xFF : 0x00]))
    }

    /// Non-negative integer from big-endian magnitude bytes (minimal encoding, sign byte added if needed).
    static func unsignedInteger(_ magnitude: Data) -> Data {
        var bytes = Array(magnitude.drop { $0 == 0 })
        if bytes.isEmpty { bytes = [0] }
        if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: 0) }
        return element(.integer, Data(bytes))
    }

    static func integer(_ value: UInt64) -> Data {
        unsignedInteger(withUnsafeBytes(of: value.bigEndian) { Data($0) })
    }

    /// BIT STRING with zero unused bits.
    static func bitString(_ bytes: Data) -> Data {
        element(.bitString, Data([0]) + bytes)
    }

    static func octetString(_ bytes: Data) -> Data {
        element(.octetString, bytes)
    }

    static func utf8String(_ string: String) -> Data {
        element(.utf8String, Data(string.utf8))
    }

    /// Dotted OID such as "1.2.840.10045.2.1". Callers pass compile-time constants only.
    static func objectIdentifier(_ dotted: String) -> Data {
        let arcs = dotted.split(separator: ".").compactMap { UInt64($0) }
        precondition(arcs.count >= 2, "OID needs at least two arcs")
        var content = base128(arcs[0] * 40 + arcs[1])
        for arc in arcs.dropFirst(2) { content.append(base128(arc)) }
        return element(.objectIdentifier, content)
    }

    /// RFC 5280: UTCTime through 2049, GeneralizedTime from 2050. Always UTC with seconds.
    static func time(_ date: Date) -> Data {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = parts.year ?? 1970
        let rest = [parts.month, parts.day, parts.hour, parts.minute, parts.second]
            .map { String(format: "%02d", $0 ?? 0) }.joined()
        if year < 2050 {
            return element(.utcTime, Data((String(format: "%02d", year % 100) + rest + "Z").utf8))
        }
        return element(.generalizedTime, Data((String(format: "%04d", year) + rest + "Z").utf8))
    }

    static func length(_ count: Int) -> Data {
        guard count >= 0x80 else { return Data([UInt8(count)]) }
        let bytes = withUnsafeBytes(of: UInt64(count).bigEndian) { Array($0) }.drop { $0 == 0 }
        return Data([0x80 | UInt8(bytes.count)]) + Data(bytes)
    }

    private static func base128(_ value: UInt64) -> Data {
        var groups: [UInt8] = [UInt8(value & 0x7F)]
        var remaining = value >> 7
        while remaining > 0 {
            groups.insert(UInt8(remaining & 0x7F) | 0x80, at: 0)
            remaining >>= 7
        }
        return Data(groups)
    }
}
