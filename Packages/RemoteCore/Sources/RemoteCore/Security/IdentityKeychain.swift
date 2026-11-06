import CryptoKit
import Foundation
import Security

public enum IdentityError: Error, Equatable, Sendable {
    case keychain(OSStatus)
    case keyGenerationFailed
    case certificate(CertificateError)
    case fingerprint(FingerprintError)
    case identityNotFound
    case invalidNamespace
}

/// Keychain items making up one device identity, scoped to a namespace:
/// - private key: `kSecClassKey`, application tag `<namespace>.identity-key` (the namespace anchor);
/// - certificate: `kSecClassCertificate`, found through its `kSecAttrPublicKeyHash`, which equals the
///   key's `kSecAttrApplicationLabel` (SHA-1 of the public key). Labels are NOT used for certificates
///   because the macOS file keychain ignores `kSecAttrLabel` on add and labels them with the CN.
/// The `SecIdentity` is the keychain pairing the two by that public key hash.
struct IdentityKeychain {
    let namespace: String

    init(namespace: String) throws(IdentityError) {
        guard !namespace.isEmpty, namespace.count <= KeychainKeyStore.maxKeyLength else { throw .invalidNamespace }
        self.namespace = namespace
    }

    var label: String { "\(namespace).identity" }
    var keyTag: Data { Data("\(namespace).identity-key".utf8) }

    // MARK: Private key

    func existingPrivateKey() throws(IdentityError) -> SecKey? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecAttrApplicationTag: keyTag,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        guard let item = try copyMatching(query) else { return nil }
        guard CFGetTypeID(item) == SecKeyGetTypeID() else { throw .identityNotFound }
        return unsafeDowncast(item, to: SecKey.self)
    }

    func createPrivateKey() throws(IdentityError) -> SecKey {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent: true,
                kSecAttrApplicationTag: keyTag,
                kSecAttrLabel: label,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
            ] as [CFString: Any],
            kSecPublicKeyAttrs: [kSecAttrIsPermanent: false] as [CFString: Any]
        ]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, nil) else { throw .keyGenerationFailed }
        return key
    }

    /// SHA-1 of the X9.63 public key: the keychain's link between a key and its certificates.
    static func publicKeyHash(x963: Data) -> Data {
        Data(Insecure.SHA1.hash(data: x963))
    }

    // MARK: Certificate

    func existingCertificate(publicKeyHash: Data) throws(IdentityError) -> SecCertificate? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecAttrPublicKeyHash: publicKeyHash,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        guard let item = try copyMatching(query) else { return nil }
        guard CFGetTypeID(item) == SecCertificateGetTypeID() else { throw .identityNotFound }
        return unsafeDowncast(item, to: SecCertificate.self)
    }

    func add(_ certificate: SecCertificate) throws(IdentityError) {
        let attributes: [CFString: Any] = [
            kSecValueRef: certificate,
            kSecAttrLabel: label,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw .keychain(status) }
    }

    func deleteCertificates(publicKeyHash: Data) throws(IdentityError) {
        try deleteMatching([kSecClass: kSecClassCertificate, kSecAttrPublicKeyHash: publicKeyHash])
    }

    /// Removes the key and its certificates. Succeeds when nothing exists.
    func deleteAll() throws(IdentityError) {
        if let key = try existingPrivateKey(),
           let publicKey = SecKeyCopyPublicKey(key),
           let x963 = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? {
            try deleteCertificates(publicKeyHash: Self.publicKeyHash(x963: x963))
        }
        try deleteMatching([kSecClass: kSecClassKey, kSecAttrApplicationTag: keyTag])
    }

    // MARK: Identity

    /// Finds the identity whose certificate is byte-for-byte `certificate`.
    func identity(for certificate: SecCertificate, publicKeyHash: Data) throws(IdentityError) -> SecIdentity {
        #if os(macOS)
        // Searches the keychain list for the private key matching the certificate's public key.
        var created: SecIdentity?
        if SecIdentityCreateWithCertificate(nil, certificate, &created) == errSecSuccess,
           let created, Self.certificateData(of: created) == SecCertificateCopyData(certificate) as Data {
            return created
        }
        #endif
        return try queriedIdentity(for: certificate, publicKeyHash: publicKeyHash)
    }

    // MARK: Helpers

    /// iOS path (and macOS fallback): identity items carry both certificate and key attributes.
    /// The iOS keychain rejects identity queries on the certificate's `kSecAttrPublicKeyHash`
    /// (`errSecNotAvailable`, seen on the iOS 26 simulator) but matches the key's
    /// `kSecAttrApplicationLabel`, which holds the same SHA-1; the macOS file keychain is the reverse.
    /// Either way only an identity whose certificate is byte-for-byte `certificate` is returned.
    func queriedIdentity(for certificate: SecCertificate, publicKeyHash: Data) throws(IdentityError) -> SecIdentity {
        let expected = SecCertificateCopyData(certificate) as Data
        #if os(iOS)
        let hashAttribute = kSecAttrApplicationLabel
        #else
        let hashAttribute = kSecAttrPublicKeyHash
        #endif
        let query: [CFString: Any] = [
            kSecClass: kSecClassIdentity,
            hashAttribute: publicKeyHash,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitAll
        ]
        let items = (try copyMatching(query) as? [AnyObject]) ?? []
        for item in items where CFGetTypeID(item) == SecIdentityGetTypeID() {
            let identity = unsafeDowncast(item, to: SecIdentity.self)
            if Self.certificateData(of: identity) == expected { return identity }
        }
        throw .identityNotFound
    }

    private static func certificateData(of identity: SecIdentity) -> Data? {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { return nil }
        return SecCertificateCopyData(certificate) as Data
    }

    private func copyMatching(_ query: [CFString: Any]) throws(IdentityError) -> CFTypeRef? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result
        case errSecItemNotFound: return nil
        default: throw .keychain(status)
        }
    }

    /// `SecItemDelete` may remove only one match on the macOS file keychain, so repeat (bounded).
    private func deleteMatching(_ query: [CFString: Any]) throws(IdentityError) {
        for _ in 0..<Self.maxDeletePasses {
            let status = SecItemDelete(query as CFDictionary)
            if status == errSecItemNotFound { return }
            guard status == errSecSuccess else { throw .keychain(status) }
        }
    }

    private static let maxDeletePasses = 16
}
