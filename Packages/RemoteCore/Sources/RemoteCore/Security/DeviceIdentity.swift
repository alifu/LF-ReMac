import Foundation
import Security

/// This device's long-term TLS identity: a Keychain-resident P-256 private key plus a self-signed
/// certificate for it. Peers pin `fingerprint` (SHA-256 of the public key), never the certificate.
///
/// The private key is generated inside the Keychain (`SecKeyCreateRandomKey`, permanent) and never
/// leaves it; keeping both key and certificate in the Keychain is what lets Security.framework hand
/// back a `SecIdentity` on macOS and iOS alike.
///
/// Immutable after creation; the wrapped CF objects are immutable and thread-safe, hence `@unchecked`.
public final class DeviceIdentity: @unchecked Sendable {
    public static let defaultNamespace = "com.alifu.lfremac.device"

    public let fingerprint: DeviceFingerprint
    public let certificate: SecCertificate
    public let certificateDER: Data
    /// Ready for `sec_identity_create` / `sec_protocol_options_set_local_identity`.
    public let secIdentity: SecIdentity

    private init(fingerprint: DeviceFingerprint, certificate: SecCertificate, secIdentity: SecIdentity) {
        self.fingerprint = fingerprint
        self.certificate = certificate
        self.certificateDER = SecCertificateCopyData(certificate) as Data
        self.secIdentity = secIdentity
    }

    /// Loads the identity stored under `namespace`, creating key and certificate on first run.
    /// An existing key is always reused (so the fingerprint stays stable); only a missing or
    /// mismatched certificate is re-issued. `deviceName` only matters when a certificate is issued.
    public static func loadOrCreate(
        deviceName: String,
        namespace: String = defaultNamespace,
        now: Date = Date()
    ) throws(IdentityError) -> DeviceIdentity {
        let keychain = try IdentityKeychain(namespace: namespace)
        return try serialized { () throws(IdentityError) in
            try load(from: keychain, deviceName: deviceName, now: now)
        }
    }

    /// Permanently removes the identity in `namespace` (all paired peers will reject this device afterwards).
    public static func delete(namespace: String = defaultNamespace) throws(IdentityError) {
        let keychain = try IdentityKeychain(namespace: namespace)
        try serialized { () throws(IdentityError) in try keychain.deleteAll() }
    }

    // MARK: Private

    /// Load-or-create is a read-modify-write and the macOS file keychain is not safe for concurrent
    /// use, so identity operations run under the shared keychain lock.
    private static func serialized<T>(_ body: () throws(IdentityError) -> T) throws(IdentityError) -> T {
        try KeychainAccess.serialized(body)
    }

    private static func load(from keychain: IdentityKeychain, deviceName: String, now: Date) throws(IdentityError) -> DeviceIdentity {
        let privateKey: SecKey
        if let existing = try keychain.existingPrivateKey() {
            privateKey = existing
        } else {
            privateKey = try keychain.createPrivateKey()
        }
        let publicKeyX963 = try publicKeyX963(of: privateKey)
        let fingerprint = try makeFingerprint(publicKeyX963)
        let keyHash = IdentityKeychain.publicKeyHash(x963: publicKeyX963)

        let certificate: SecCertificate
        if let existing = try keychain.existingCertificate(publicKeyHash: keyHash), certificateMatches(existing, fingerprint) {
            certificate = existing
        } else {
            certificate = try issueCertificate(
                in: keychain, privateKey: privateKey, publicKeyX963: publicKeyX963, deviceName: deviceName, now: now
            )
        }
        let identity = try keychain.identity(for: certificate, publicKeyHash: keyHash)
        return DeviceIdentity(fingerprint: fingerprint, certificate: certificate, secIdentity: identity)
    }

    private static func issueCertificate(
        in keychain: IdentityKeychain, privateKey: SecKey, publicKeyX963: Data, deviceName: String, now: Date
    ) throws(IdentityError) -> SecCertificate {
        var rng = SystemRandomNumberGenerator()
        let der: Data
        do {
            der = try SelfSignedCertificate.make(
                commonName: deviceName,
                publicKeyX963: publicKeyX963,
                serial: SelfSignedCertificate.randomSerial(using: &rng),
                now: now,
                sign: { try sign($0, with: privateKey) }
            )
        } catch {
            throw .certificate(error)
        }
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw .certificate(.unparsable)
        }
        try keychain.deleteCertificates(publicKeyHash: IdentityKeychain.publicKeyHash(x963: publicKeyX963))
        try keychain.add(certificate)
        return certificate
    }

    private static func sign(_ message: Data, with key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            key, .ecdsaSignatureMessageX962SHA256, message as CFData, &error
        ) as Data? else {
            throw IdentityError.certificate(.signingFailed)
        }
        return signature
    }

    private static func publicKeyX963(of privateKey: SecKey) throws(IdentityError) -> Data {
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let data = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            throw .fingerprint(.unsupportedKey)
        }
        return data
    }

    private static func makeFingerprint(_ x963: Data) throws(IdentityError) -> DeviceFingerprint {
        do {
            return try DeviceFingerprint(publicKeyX963: x963)
        } catch {
            throw .fingerprint(error)
        }
    }

    private static func certificateMatches(_ certificate: SecCertificate, _ fingerprint: DeviceFingerprint) -> Bool {
        (try? DeviceFingerprint(certificate: certificate)) == fingerprint
    }
}
