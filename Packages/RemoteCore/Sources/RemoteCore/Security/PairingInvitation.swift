import Foundation

public enum PairingInvitationError: Error, Equatable, Sendable {
    case tooLong
    case notAnInvitation
    case unsupportedVersion
    case missingField(String)
    case duplicateField(String)
    case unknownField
    case invalidHost
    case invalidPort
    case invalidFingerprint
    case invalidSecret
}

/// QR payload shown in the Mac's "Pair New iPhone" window:
/// `lfremac://pair?v=1&h=<host>&p=<port>&f=<64 hex>&s=<16 base32>`.
///
/// Parsing treats the string as hostile (it comes from a camera): exact scheme/path, known version,
/// every field present exactly once, no unknown fields, strict host/port/fingerprint/secret syntax.
public struct PairingInvitation: Equatable, Sendable, CustomStringConvertible {
    public static let version = "1"
    public static let maxLength = 512
    public static let maxHostLength = 253
    static let scheme = "lfremac"
    static let path = "pair"
    private static let fieldNames: Set<String> = ["v", "h", "p", "f", "s"]

    /// DNS name, IPv4 or IPv6 literal the iPhone connects to.
    public let host: String
    public let port: UInt16
    public let hostFingerprint: DeviceFingerprint
    public let secret: PairingSecret

    public init(host: String, port: UInt16, hostFingerprint: DeviceFingerprint, secret: PairingSecret) throws(PairingInvitationError) {
        guard Self.isValidHost(host) else { throw .invalidHost }
        guard port > 0 else { throw .invalidPort }
        self.host = host
        self.port = port
        self.hostFingerprint = hostFingerprint
        self.secret = secret
    }

    /// Every field uses only URL-safe characters (host syntax is validated), so no escaping is needed.
    public var urlString: String {
        "\(Self.scheme)://\(Self.path)?v=\(Self.version)&h=\(host)&p=\(port)&f=\(hostFingerprint)&s=\(secret.compactCode)"
    }

    /// Redacted: never includes the secret (use `urlString` for the QR code only).
    public var description: String {
        "PairingInvitation(host: \(host), port: \(port), hostFingerprint: \(hostFingerprint))"
    }

    public init(urlString: String) throws(PairingInvitationError) {
        guard urlString.utf8.count <= Self.maxLength else { throw .tooLong }
        let fields = try Self.fields(of: urlString)
        guard try Self.field("v", in: fields) == Self.version else { throw .unsupportedVersion }
        try self.init(
            host: try Self.field("h", in: fields),
            port: try Self.port(try Self.field("p", in: fields)),
            hostFingerprint: try Self.fingerprint(try Self.field("f", in: fields)),
            secret: try Self.secret(try Self.field("s", in: fields))
        )
    }

    // MARK: Parsing helpers

    private static func fields(of urlString: String) throws(PairingInvitationError) -> [String: String] {
        let prefix = "\(scheme)://\(path)?"
        guard urlString.hasPrefix(prefix) else { throw .notAnInvitation }
        let query = urlString.dropFirst(prefix.count)
        var fields: [String: String] = [:]
        for pair in query.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw .notAnInvitation }
            let name = String(parts[0])
            guard fieldNames.contains(name) else { throw .unknownField }
            guard fields[name] == nil else { throw .duplicateField(name) }
            fields[name] = String(parts[1])
        }
        return fields
    }

    private static func field(_ name: String, in fields: [String: String]) throws(PairingInvitationError) -> String {
        guard let value = fields[name] else { throw .missingField(name) }
        return value
    }

    /// 1-5 ASCII digits, no sign, no leading zero, 1...65535.
    private static func port(_ text: String) throws(PairingInvitationError) -> UInt16 {
        let digits = Array(text.utf8)
        guard (1...5).contains(digits.count), digits.first != UInt8(ascii: "0"),
              digits.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
              let value = UInt16(text) else {
            throw .invalidPort
        }
        return value
    }

    private static func fingerprint(_ text: String) throws(PairingInvitationError) -> DeviceFingerprint {
        do {
            return try DeviceFingerprint(hex: text)
        } catch {
            throw .invalidFingerprint
        }
    }

    /// The QR form must be canonical (16 uppercase symbols, no separators, no look-alikes).
    private static func secret(_ text: String) throws(PairingInvitationError) -> PairingSecret {
        guard text.utf8.count == PairingSecret.symbolCount,
              let secret = try? PairingSecret(code: text), secret.compactCode == text else {
            throw .invalidSecret
        }
        return secret
    }

    /// Letters, digits, `.`, `-`, and for IPv6 literals `:` (no brackets, no zone IDs, no `%` escapes).
    static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= maxHostLength else { return false }
        return host.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-" || scalar == ":")
        }
    }
}
