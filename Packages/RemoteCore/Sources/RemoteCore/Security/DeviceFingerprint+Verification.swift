import Foundation

extension DeviceFingerprint {
    private static let verificationBytes = 8
    private static let verificationGroupSize = 4

    /// Short code a person can compare on two screens, e.g. `A1B2-C3D4-E5F6-0718`.
    /// 64 bits of the fingerprint: too many to grind a look-alike key for, short enough to read aloud.
    public var verificationCode: String {
        let hex = bytes.prefix(Self.verificationBytes).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: hex.count, by: Self.verificationGroupSize)
            .map { offset -> String in
                let start = hex.index(hex.startIndex, offsetBy: offset)
                let end = hex.index(start, offsetBy: Self.verificationGroupSize)
                return String(hex[start..<end])
            }
            .joined(separator: "-")
    }
}
