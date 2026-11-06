import Foundation

public enum PairingSecretError: Error, Equatable, Sendable {
    case invalidLength
    case invalidCharacter
}

/// One-time pairing secret: 10 random bytes (80 bits), shown as `XXXX-XXXX-XXXX-XXXX` in
/// Crockford base32. 80 bits keeps an offline brute force by a man-in-the-middle out of reach.
///
/// `description` is redacted so the secret cannot leak into logs by accident; use `displayCode`
/// only for the pairing window / QR payload.
public struct PairingSecret: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public static let byteCount = 10
    static let symbolCount = 16
    static let groupLength = 4
    /// Generous cap on raw user input before any processing (dashes, spaces, pasted whitespace).
    static let maxInputLength = 64

    public let bytes: Data

    public init(bytes: Data) throws(PairingSecretError) {
        guard bytes.count == Self.byteCount else { throw .invalidLength }
        self.bytes = Data(bytes)
    }

    /// Parses user input or a QR value: case-insensitive, ignores `-` and spaces, maps O->0 and
    /// I/L->1, rejects anything else.
    public init(code: String) throws(PairingSecretError) {
        guard code.utf8.count <= Self.maxInputLength else { throw .invalidLength }
        var compact = String.UnicodeScalarView()
        compact.append(contentsOf: code.unicodeScalars.filter { $0 != "-" && $0 != " " })
        guard compact.allSatisfy(\.isASCII) else { throw .invalidCharacter }
        guard compact.count == Self.symbolCount else { throw .invalidLength }
        guard let bytes = CrockfordBase32.decode(String(compact)) else { throw .invalidCharacter }
        try self.init(bytes: bytes)
    }

    public static func random() -> PairingSecret {
        var generator = SystemRandomNumberGenerator()
        return random(using: &generator)
    }

    /// Inject a generator in tests; production must use a CSPRNG (`SystemRandomNumberGenerator`).
    public static func random<G: RandomNumberGenerator>(using generator: inout G) -> PairingSecret {
        let bytes = Data((0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        return PairingSecret(unchecked: bytes)
    }

    /// Only for byte arrays whose length is `byteCount` by construction.
    private init(unchecked bytes: Data) {
        self.bytes = bytes
    }

    /// 16 symbols without separators (QR payload form).
    public var compactCode: String {
        CrockfordBase32.encode(bytes) ?? ""
    }

    /// `XXXX-XXXX-XXXX-XXXX` for display.
    public var displayCode: String {
        let symbols = Array(compactCode)
        return stride(from: 0, to: symbols.count, by: Self.groupLength)
            .map { String(symbols[$0..<min($0 + Self.groupLength, symbols.count)]) }
            .joined(separator: "-")
    }

    public var description: String { "PairingSecret(redacted)" }
    public var debugDescription: String { description }
    /// Keeps `dump`, debugger summaries and `String(reflecting:)` of containing types from showing the bytes.
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}
