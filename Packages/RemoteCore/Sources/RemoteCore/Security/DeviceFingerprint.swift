import CryptoKit
import Foundation
import Security

public enum FingerprintError: Error, Equatable, Sendable {
    case invalidLength(Int)
    case invalidHex
    /// The key is not an uncompressed P-256 public key.
    case unsupportedKey
    case missingPublicKey
}

/// SHA-256 of a device's P-256 public key in X9.63 form (`04 || X || Y`).
///
/// Binding pairing to the key, not the certificate, means a re-issued certificate keeps working.
/// Fingerprints are public values (hashes of public keys); `==` is fine for lookups, and
/// `constantTimeEquals` exists for places where the comparison sits next to secret-dependent code.
public struct DeviceFingerprint: Hashable, Sendable, CustomStringConvertible {
    public static let byteCount = 32
    static let p256X963Length = 65

    public let bytes: Data

    public init(bytes: Data) throws(FingerprintError) {
        guard bytes.count == Self.byteCount else { throw .invalidLength(bytes.count) }
        self.bytes = Data(bytes)
    }

    public init(hex: String) throws(FingerprintError) {
        guard hex.utf8.count == Self.byteCount * 2, let bytes = Hex.decode(hex) else { throw .invalidHex }
        try self.init(bytes: bytes)
    }

    /// - Parameter publicKeyX963: uncompressed P-256 point, 65 bytes starting with `0x04`.
    public init(publicKeyX963: Data) throws(FingerprintError) {
        guard publicKeyX963.count == Self.p256X963Length, publicKeyX963.first == 0x04,
              (try? P256.Signing.PublicKey(x963Representation: publicKeyX963)) != nil else {
            throw .unsupportedKey
        }
        try self.init(bytes: Data(SHA256.hash(data: publicKeyX963)))
    }

    public init(publicKey: SecKey) throws(FingerprintError) {
        guard let attributes = SecKeyCopyAttributes(publicKey) as? [CFString: Any],
              attributes[kSecAttrKeyType] as? String == kSecAttrKeyTypeECSECPrimeRandom as String,
              attributes[kSecAttrKeyClass] as? String == kSecAttrKeyClassPublic as String,
              let external = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            throw .unsupportedKey
        }
        try self.init(publicKeyX963: external)
    }

    /// Fingerprint of the public key inside a (peer's) certificate. Does not evaluate trust.
    public init(certificate: SecCertificate) throws(FingerprintError) {
        guard let key = SecCertificateCopyKey(certificate) else { throw .missingPublicKey }
        try self.init(publicKey: key)
    }

    /// Lowercase hex, 64 characters.
    public var description: String { Hex.encode(bytes) }

    public func constantTimeEquals(_ other: DeviceFingerprint) -> Bool {
        guard bytes.count == other.bytes.count else { return false }
        let difference = zip(bytes, other.bytes).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) }
        return difference == 0
    }
}

extension DeviceFingerprint: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let hex = try container.decode(String.self)
        do {
            try self.init(hex: hex)
        } catch {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid fingerprint")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
