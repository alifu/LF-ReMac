import Foundation
import Security
import Testing
@testable import RemoteCore

/// Uses the real Keychain under a unique, throw-away namespace per test and deletes it afterwards.
struct DeviceIdentityTests {
    @Test func createsIdentityWhoseCertificateParsesAndMatchesFingerprint() throws {
        try TestIdentity.withIdentity(name: "Test Mac") { identity, _ in
            let parsed = try #require(SecCertificateCreateWithData(nil, identity.certificateDER as CFData))
            #expect(try DeviceFingerprint(certificate: parsed) == identity.fingerprint)
            #expect(SecCertificateCopySubjectSummary(parsed) as String? == "Test Mac")
        }
    }

    @Test func secIdentityCarriesTheSameCertificateAndAUsablePrivateKey() throws {
        try TestIdentity.withIdentity(name: "Signer") { identity, _ in
            var certificate: SecCertificate?
            #expect(SecIdentityCopyCertificate(identity.secIdentity, &certificate) == errSecSuccess)
            #expect(certificate.map { SecCertificateCopyData($0) as Data } == identity.certificateDER)

            var key: SecKey?
            #expect(SecIdentityCopyPrivateKey(identity.secIdentity, &key) == errSecSuccess)
            let privateKey = try #require(key)
            let message = Data("hello".utf8)
            let signature = try #require(
                SecKeyCreateSignature(privateKey, .ecdsaSignatureMessageX962SHA256, message as CFData, nil)
            )
            let leaf = try #require(certificate)
            let publicKey = try #require(SecCertificateCopyKey(leaf))
            #expect(SecKeyVerifySignature(publicKey, .ecdsaSignatureMessageX962SHA256, message as CFData, signature, nil))
        }
    }

    @Test func reloadingReturnsTheSameFingerprintAndCertificate() throws {
        try TestIdentity.withIdentity(name: "Stable") { identity, namespace in
            let reloaded = try DeviceIdentity.loadOrCreate(deviceName: "Other Name", namespace: namespace)
            #expect(reloaded.fingerprint == identity.fingerprint)
            #expect(reloaded.certificateDER == identity.certificateDER)
        }
    }

    @Test func differentNamespacesHaveDifferentFingerprints() throws {
        try TestIdentity.withIdentity(name: "A") { first, _ in
            try TestIdentity.withIdentity(name: "B") { second, _ in
                #expect(first.fingerprint != second.fingerprint)
            }
        }
    }

    @Test func deletingRemovesTheIdentitySoANewKeyIsCreated() throws {
        let namespace = TestIdentity.uniqueNamespace()
        defer { try? DeviceIdentity.delete(namespace: namespace) }
        let first = try DeviceIdentity.loadOrCreate(deviceName: "X", namespace: namespace)

        try DeviceIdentity.delete(namespace: namespace)
        let second = try DeviceIdentity.loadOrCreate(deviceName: "X", namespace: namespace)

        #expect(first.fingerprint != second.fingerprint)
    }

    @Test func identityQueryPathUsedOnIOSAlsoFindsTheIdentity() throws {
        try TestIdentity.withIdentity(name: "Query") { identity, namespace in
            let keychain = try IdentityKeychain(namespace: namespace)
            let key = try #require(SecCertificateCopyKey(identity.certificate))
            let x963 = try #require(SecKeyCopyExternalRepresentation(key, nil) as Data?)

            let queried = try keychain.queriedIdentity(
                for: identity.certificate, publicKeyHash: IdentityKeychain.publicKeyHash(x963: x963)
            )

            var certificate: SecCertificate?
            #expect(SecIdentityCopyCertificate(queried, &certificate) == errSecSuccess)
            #expect(certificate.map { SecCertificateCopyData($0) as Data } == identity.certificateDER)
        }
    }

    @Test func missingCertificateIsReissuedForTheSameKey() throws {
        try TestIdentity.withIdentity(name: "Reissue") { identity, namespace in
            let keychain = try IdentityKeychain(namespace: namespace)
            let key = try #require(SecCertificateCopyKey(identity.certificate))
            let x963 = try #require(SecKeyCopyExternalRepresentation(key, nil) as Data?)
            try keychain.deleteCertificates(publicKeyHash: IdentityKeychain.publicKeyHash(x963: x963))

            let reloaded = try DeviceIdentity.loadOrCreate(deviceName: "Reissue", namespace: namespace)

            #expect(reloaded.fingerprint == identity.fingerprint)
            #expect(reloaded.certificateDER != identity.certificateDER)
        }
    }

    @Test func deletingAMissingIdentitySucceeds() throws {
        try DeviceIdentity.delete(namespace: TestIdentity.uniqueNamespace())
    }

    @Test func rejectsEmptyNamespace() {
        #expect(throws: IdentityError.invalidNamespace) {
            try DeviceIdentity.loadOrCreate(deviceName: "X", namespace: "")
        }
    }
}

enum TestIdentity {
    static func uniqueNamespace() -> String {
        "com.alifu.lfremac.tests.\(UUID().uuidString)"
    }

    static func withIdentity<T>(name: String, _ body: (DeviceIdentity, String) throws -> T) throws -> T {
        let namespace = uniqueNamespace()
        defer { try? DeviceIdentity.delete(namespace: namespace) }
        let identity = try DeviceIdentity.loadOrCreate(deviceName: name, namespace: namespace)
        return try body(identity, namespace)
    }

    static func withIdentity<T>(name: String, _ body: (DeviceIdentity, String) async throws -> T) async throws -> T {
        let namespace = uniqueNamespace()
        defer { try? DeviceIdentity.delete(namespace: namespace) }
        let identity = try DeviceIdentity.loadOrCreate(deviceName: name, namespace: namespace)
        return try await body(identity, namespace)
    }
}
