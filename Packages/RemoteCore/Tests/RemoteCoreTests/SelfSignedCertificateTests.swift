import CryptoKit
import Foundation
import Security
import Testing
@testable import RemoteCore

/// Certificate encoding checked without the Keychain: sign with a CryptoKit key, parse with Security.
struct SelfSignedCertificateTests {
    private let key = P256.Signing.PrivateKey()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeCertificate(name: String = "Ali's Mac mini", serial: Data = Data(repeating: 0xFF, count: 16)) throws -> Data {
        try SelfSignedCertificate.make(
            commonName: name, publicKeyX963: key.publicKey.x963Representation, serial: serial, now: now,
            sign: { try key.signature(for: $0).derRepresentation }
        )
    }

    @Test func parsesBackWithTheSamePublicKeyAndCommonName() throws {
        let der = try makeCertificate()

        let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))

        #expect(try DeviceFingerprint(certificate: certificate) == DeviceFingerprint(publicKeyX963: key.publicKey.x963Representation))
        #expect(SecCertificateCopySubjectSummary(certificate) as String? == "Ali's Mac mini")
    }

    @Test func signatureVerifiesOverTheTBSCertificate() throws {
        let der = try makeCertificate()
        let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))
        let publicKey = try #require(SecCertificateCopyKey(certificate))
        let policy = SecPolicyCreateBasicX509()
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates(certificate, policy, &trust) == errSecSuccess)
        let secTrust = try #require(trust)
        #expect(SecTrustSetAnchorCertificates(secTrust, [certificate] as CFArray) == errSecSuccess)
        #expect(SecTrustSetVerifyDate(secTrust, now as CFDate) == errSecSuccess)

        // A self-signed certificate anchored to itself evaluates only if its signature is valid.
        #expect(SecTrustEvaluateWithError(secTrust, nil))
        #expect(SecKeyIsAlgorithmSupported(publicKey, .verify, .ecdsaSignatureMessageX962SHA256))
    }

    @Test func emptyNameFallsBackAndLongNamesAreTruncated() throws {
        let empty = try #require(SecCertificateCreateWithData(nil, try makeCertificate(name: "  ") as CFData))
        let long = try #require(SecCertificateCreateWithData(nil, try makeCertificate(name: String(repeating: "x", count: 300)) as CFData))

        #expect(SecCertificateCopySubjectSummary(empty) as String? == "LF-ReMac Device")
        #expect((SecCertificateCopySubjectSummary(long) as String?)?.count == SelfSignedCertificate.maxCommonNameLength)
    }

    @Test func serialIsPositiveEvenWhenTopBitIsSet() throws {
        let certificate = try #require(SecCertificateCreateWithData(nil, try makeCertificate() as CFData))
        let serial = try #require(SecCertificateCopySerialNumberData(certificate, nil) as Data?)

        #expect(serial.first.map { $0 & 0x80 } == 0)
    }

    @Test func rejectsANonP256PublicKey() {
        #expect(throws: CertificateError.invalidPublicKey) {
            try SelfSignedCertificate.make(commonName: "x", publicKeyX963: Data(count: 33), serial: Data([1]), now: now) { $0 }
        }
    }

    @Test func reportsSigningFailure() {
        struct Boom: Error {}
        #expect(throws: CertificateError.signingFailed) {
            try SelfSignedCertificate.make(
                commonName: "x", publicKeyX963: key.publicKey.x963Representation, serial: Data([1]), now: now
            ) { _ in throw Boom() }
        }
    }

    @Test func derLengthUsesLongFormAbove127Bytes() {
        #expect(DER.length(127) == Data([0x7F]))
        #expect(DER.length(128) == Data([0x81, 0x80]))
        #expect(DER.length(300) == Data([0x82, 0x01, 0x2C]))
    }

    @Test func derEncodesKnownOIDAndIntegers() {
        #expect(DER.objectIdentifier("1.2.840.10045.2.1") == Data([0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]))
        #expect(DER.integer(2) == Data([0x02, 0x01, 0x02]))
        #expect(DER.unsignedInteger(Data([0x00, 0x80])) == Data([0x02, 0x02, 0x00, 0x80]))
        #expect(DER.unsignedInteger(Data()) == Data([0x02, 0x01, 0x00]))
    }

    @Test func derTimeSwitchesToGeneralizedTimeIn2050() {
        let in2049 = Date(timeIntervalSince1970: 2_524_607_999) // 2049-12-31T23:59:59Z
        let in2050 = Date(timeIntervalSince1970: 2_524_608_000) // 2050-01-01T00:00:00Z

        #expect(DER.time(in2049) == DER.element(.utcTime, Data("491231235959Z".utf8)))
        #expect(DER.time(in2050) == DER.element(.generalizedTime, Data("20500101000000Z".utf8)))
    }
}
