import Foundation

public enum CertificateError: Error, Equatable, Sendable {
    case invalidPublicKey
    case signingFailed
    case unparsable
}

/// Builds a minimal self-signed X.509 v3 certificate (RFC 5280) for a P-256 key, signed ECDSA-SHA256.
///
/// The certificate only exists because TLS needs one; peers never trust it through a CA, they pin
/// the SHA-256 of its public key (`DeviceFingerprint`). Choices:
/// - serial: 16 random bytes, top bit cleared (positive, <= 20 octets as RFC 5280 requires);
/// - validity: `notBefore` = now - 1 day (clock skew), `notAfter` = now + 10 years (expiry is not
///   enforced by the pinning verify block, it is only informative);
/// - subject = issuer = `CN=<device name>` (trimmed to 64 characters);
/// - extensions: basicConstraints CA:false (critical), keyUsage digitalSignature (critical),
///   extendedKeyUsage serverAuth + clientAuth, so the same identity works for both TLS roles.
enum SelfSignedCertificate {
    static let validityYears = 10
    static let clockSkewAllowance: TimeInterval = 24 * 60 * 60
    static let maxCommonNameLength = 64
    static let serialByteCount = 16

    private enum OID {
        static let ecPublicKey = "1.2.840.10045.2.1"
        static let prime256v1 = "1.2.840.10045.3.1.7"
        static let ecdsaWithSHA256 = "1.2.840.10045.4.3.2"
        static let commonName = "2.5.4.3"
        static let basicConstraints = "2.5.29.19"
        static let keyUsage = "2.5.29.15"
        static let extendedKeyUsage = "2.5.29.37"
        static let serverAuth = "1.3.6.1.5.5.7.3.1"
        static let clientAuth = "1.3.6.1.5.5.7.3.2"
    }

    /// - Parameters:
    ///   - publicKeyX963: uncompressed P-256 public key (65 bytes).
    ///   - sign: returns a DER-encoded ECDSA-SHA256 signature over the given bytes.
    static func make(
        commonName: String,
        publicKeyX963: Data,
        serial: Data,
        now: Date,
        sign: (Data) throws -> Data
    ) throws(CertificateError) -> Data {
        guard publicKeyX963.count == DeviceFingerprint.p256X963Length, publicKeyX963.first == 0x04 else {
            throw .invalidPublicKey
        }
        let tbs = tbsCertificate(
            name: name(commonName), publicKeyX963: publicKeyX963,
            serial: positiveSerial(serial), validity: validity(now: now)
        )
        let signature: Data
        do {
            signature = try sign(tbs)
        } catch {
            throw .signingFailed
        }
        return DER.sequence([tbs, signatureAlgorithm, DER.bitString(signature)])
    }

    static func randomSerial<G: RandomNumberGenerator>(using generator: inout G) -> Data {
        Data((0..<serialByteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    private static var signatureAlgorithm: Data {
        DER.sequence([DER.objectIdentifier(OID.ecdsaWithSHA256)])
    }

    private static func tbsCertificate(name: Data, publicKeyX963: Data, serial: Data, validity: Data) -> Data {
        DER.sequence([
            DER.explicit(0, DER.integer(2)),
            DER.unsignedInteger(serial),
            signatureAlgorithm,
            name,
            validity,
            name,
            subjectPublicKeyInfo(publicKeyX963),
            DER.explicit(3, extensions)
        ])
    }

    private static func name(_ commonName: String) -> Data {
        let trimmed = commonName.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = String((trimmed.isEmpty ? "LF-ReMac Device" : trimmed).prefix(maxCommonNameLength))
        let attribute = DER.sequence([DER.objectIdentifier(OID.commonName), DER.utf8String(value)])
        return DER.sequence([DER.set([attribute])])
    }

    private static func validity(now: Date) -> Data {
        let notBefore = now.addingTimeInterval(-clockSkewAllowance)
        let notAfter = Calendar(identifier: .gregorian).date(byAdding: .year, value: validityYears, to: now)
            ?? now.addingTimeInterval(Double(validityYears) * 365.25 * 24 * 60 * 60)
        return DER.sequence([DER.time(notBefore), DER.time(notAfter)])
    }

    private static func subjectPublicKeyInfo(_ publicKeyX963: Data) -> Data {
        let algorithm = DER.sequence([DER.objectIdentifier(OID.ecPublicKey), DER.objectIdentifier(OID.prime256v1)])
        return DER.sequence([algorithm, DER.bitString(publicKeyX963)])
    }

    private static var extensions: Data {
        let basicConstraints = DER.sequence([])
        let keyUsageDigitalSignature = DER.element(.bitString, Data([0x07, 0x80]))
        let extendedKeyUsage = DER.sequence([DER.objectIdentifier(OID.serverAuth), DER.objectIdentifier(OID.clientAuth)])
        return DER.sequence([
            certificateExtension(OID.basicConstraints, critical: true, value: basicConstraints),
            certificateExtension(OID.keyUsage, critical: true, value: keyUsageDigitalSignature),
            certificateExtension(OID.extendedKeyUsage, critical: false, value: extendedKeyUsage)
        ])
    }

    private static func certificateExtension(_ oid: String, critical: Bool, value: Data) -> Data {
        var parts = [DER.objectIdentifier(oid)]
        if critical { parts.append(DER.boolean(true)) }
        parts.append(DER.octetString(value))
        return DER.sequence(parts)
    }

    /// Clears the top bit and avoids an all-zero serial so the INTEGER is positive and non-zero.
    private static func positiveSerial(_ serial: Data) -> Data {
        var bytes = Array(serial.prefix(serialByteCount))
        if bytes.isEmpty { bytes = [1] }
        bytes[0] &= 0x7F
        if bytes.allSatisfy({ $0 == 0 }) { bytes[bytes.count - 1] = 1 }
        return Data(bytes)
    }
}
