import Foundation

/// A 6-byte hardware address. Never all-zero or broadcast, so a bad value cannot become a packet.
public struct MACAddress: Hashable, Sendable, CustomStringConvertible {
    public static let byteCount = 6

    public let bytes: [UInt8]

    public init?(bytes: [UInt8]) {
        guard bytes.count == Self.byteCount,
              bytes.contains(where: { $0 != 0x00 }),
              bytes.contains(where: { $0 != 0xFF })
        else { return nil }
        self.bytes = bytes
    }

    /// Accepts `aa:bb:cc:01:02:03` or `AA-BB-CC-01-02-03`; one separator style per address.
    public init?(_ text: String) {
        let separator: Character
        if text.contains(":") && !text.contains("-") {
            separator = ":"
        } else if text.contains("-") && !text.contains(":") {
            separator = "-"
        } else {
            return nil
        }
        let parts = text.split(separator: separator, omittingEmptySubsequences: false)
        guard parts.count == Self.byteCount, parts.allSatisfy({ $0.count == 2 }) else { return nil }
        let parsed = parts.compactMap { UInt8($0, radix: 16) }
        guard parsed.count == Self.byteCount else { return nil }
        self.init(bytes: parsed)
    }

    public var description: String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}

/// The Wake-on-LAN "magic packet": six 0xFF bytes, then the target address sixteen times (102 bytes).
public enum MagicPacket {
    public static func data(for mac: MACAddress) -> Data {
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: mac.bytes) }
        return packet
    }
}

/// The IPv4 broadcast address of a subnet (`ip | ~netmask`).
public enum DirectedBroadcast {
    public static func address(ip: String, netmask: String) -> String? {
        guard let ipValue = value(of: ip), let maskValue = value(of: netmask) else { return nil }
        // A usable subnet mask is a run of ones followed by a run of zeros, with at least two host addresses.
        let hostBits = ~maskValue
        guard hostBits & (hostBits &+ 1) == 0, hostBits != 0, maskValue != 0 else { return nil }
        let broadcast = ipValue | hostBits
        return (0..<4).map { String((broadcast >> UInt32(24 - 8 * $0)) & 0xFF) }.joined(separator: ".")
    }

    private static func value(of dotted: String) -> UInt32? {
        let parts = dotted.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: UInt32 = 0
        for part in parts {
            guard let octet = UInt8(part) else { return nil }
            result = result << 8 | UInt32(octet)
        }
        return result
    }
}
