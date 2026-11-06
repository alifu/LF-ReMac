import CryptoKit
import Foundation
import Security
import Testing
@testable import RemoteCore

struct DeviceFingerprintTests {
    @Test func isSHA256OfTheX963PublicKey() throws {
        let key = P256.Signing.PrivateKey().publicKey

        let fingerprint = try DeviceFingerprint(publicKeyX963: key.x963Representation)

        #expect(fingerprint.bytes == Data(SHA256.hash(data: key.x963Representation)))
        #expect(fingerprint.bytes.count == 32)
    }

    @Test func secKeyAndCryptoKitKeyGiveTheSameFingerprint() throws {
        let key = P256.Signing.PrivateKey().publicKey
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        let secKey = try #require(SecKeyCreateWithData(key.x963Representation as CFData, attributes as CFDictionary, nil))

        #expect(try DeviceFingerprint(publicKey: secKey) == DeviceFingerprint(publicKeyX963: key.x963Representation))
    }

    @Test func descriptionIsLowercaseHexAndRoundTrips() throws {
        let fingerprint = try DeviceFingerprint(bytes: Data((0..<32).map { UInt8($0 * 7) }))

        #expect(fingerprint.description.count == 64)
        #expect(fingerprint.description == fingerprint.description.lowercased())
        #expect(try DeviceFingerprint(hex: fingerprint.description) == fingerprint)
        #expect(try DeviceFingerprint(hex: fingerprint.description.uppercased()) == fingerprint)
    }

    @Test(arguments: ["", "abc", String(repeating: "g", count: 64), String(repeating: "a", count: 63), String(repeating: "a", count: 66), String(repeating: "é", count: 32)])
    func rejectsMalformedHex(hex: String) {
        #expect(throws: FingerprintError.invalidHex) { try DeviceFingerprint(hex: hex) }
    }

    @Test(arguments: [0, 31, 33, 64])
    func rejectsWrongByteCount(count: Int) {
        #expect(throws: FingerprintError.invalidLength(count)) { try DeviceFingerprint(bytes: Data(count: count)) }
    }

    @Test func rejectsKeysThatAreNotUncompressedP256Points() {
        let compressed = P256.Signing.PrivateKey().publicKey.compressedRepresentation
        let notOnCurve = Data([0x04]) + Data(repeating: 0x01, count: 64)

        #expect(throws: FingerprintError.unsupportedKey) { try DeviceFingerprint(publicKeyX963: compressed) }
        #expect(throws: FingerprintError.unsupportedKey) { try DeviceFingerprint(publicKeyX963: notOnCurve) }
    }

    @Test func rejectsRSAKeys() throws {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        let privateKey = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try #require(SecKeyCopyPublicKey(privateKey))

        #expect(throws: FingerprintError.unsupportedKey) { try DeviceFingerprint(publicKey: publicKey) }
    }

    @Test func rejectsPrivateKeys() throws {
        let key = P256.Signing.PrivateKey()
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        let secKey = try #require(SecKeyCreateWithData(key.x963Representation as CFData, attributes as CFDictionary, nil))

        #expect(throws: FingerprintError.unsupportedKey) { try DeviceFingerprint(publicKey: secKey) }
    }

    @Test func constantTimeEqualsMatchesEquality() {
        #expect(Fixtures.host.constantTimeEquals(Fixtures.host))
        #expect(!Fixtures.host.constantTimeEquals(Fixtures.phone))
    }

    @Test func codableUsesHexAndRejectsGarbage() throws {
        let encoded = try JSONEncoder().encode([Fixtures.host])

        #expect(String(decoding: encoded, as: UTF8.self) == "[\"\(Fixtures.host)\"]")
        #expect(try JSONDecoder().decode([DeviceFingerprint].self, from: encoded) == [Fixtures.host])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([DeviceFingerprint].self, from: Data("[\"zz\"]".utf8)) }
    }
}
