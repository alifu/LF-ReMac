import Foundation
import Testing
@testable import RemoteCore

struct PairingSecretTests {
    @Test func randomSecretHasEightyBitsAndSixteenSymbols() {
        let secret = PairingSecret.random()

        #expect(secret.bytes.count == 10)
        #expect(secret.compactCode.count == 16)
        #expect(secret.displayCode.count == 19)
    }

    @Test func displayCodeIsFourGroupsOfFour() {
        let groups = Fixtures.secret().displayCode.split(separator: "-")

        #expect(groups.count == 4)
        #expect(groups.allSatisfy { $0.count == 4 })
    }

    @Test func codeUsesOnlyUnambiguousSymbols() {
        for seed in UInt64(0)..<200 {
            let code = Fixtures.secret(seed: seed).compactCode
            #expect(code.allSatisfy { "0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains($0) })
        }
    }

    @Test(arguments: UInt64(0)..<50)
    func displayAndCompactCodesRoundTrip(seed: UInt64) throws {
        let secret = Fixtures.secret(seed: seed)

        #expect(try PairingSecret(code: secret.displayCode) == secret)
        #expect(try PairingSecret(code: secret.compactCode) == secret)
    }

    @Test func knownBytesEncodeToKnownCode() throws {
        let secret = try PairingSecret(bytes: Data([0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]))

        #expect(secret.displayCode == "0000-0000-ZZZZ-ZZZZ")
    }

    @Test func parsingIsCaseInsensitiveAndMapsLookAlikes() throws {
        let secret = try PairingSecret(code: "0000-0000-ZZZZ-ZZZZ")

        #expect(try PairingSecret(code: "oOoO oooo zzzz zzzz") == secret)
        #expect(try PairingSecret(code: "1111-1111-1111-1111") == PairingSecret(code: "iIlL-1111-1111-1111"))
    }

    @Test(arguments: ["", "0000-0000-ZZZZ-ZZZ", "0000-0000-ZZZZ-ZZZZZ", String(repeating: "-", count: 100)])
    func rejectsWrongLength(code: String) {
        #expect(throws: PairingSecretError.invalidLength) { try PairingSecret(code: code) }
    }

    @Test(arguments: ["0000-0000-ZZZZ-ZZZU", "0000-0000-ZZZZ-ZZZ!", "0000_0000_ZZZZ_ZZZZ", "0000-0000-ZZZZ-ZZZé", "0000-0000-ZZZZ-ZZZ\u{0}"])
    func rejectsCharactersOutsideTheAlphabet(code: String) {
        #expect(throws: PairingSecretError.self) { try PairingSecret(code: code) }
    }

    @Test(arguments: [9, 11, 0])
    func rejectsWrongByteCount(count: Int) {
        #expect(throws: PairingSecretError.invalidLength) { try PairingSecret(bytes: Data(count: count)) }
    }

    @Test func neverPrintsTheSecret() {
        let secret = Fixtures.secret()
        var dumped = ""
        dump(secret, to: &dumped)

        #expect(!"\(secret)".contains(secret.compactCode))
        #expect(!String(reflecting: secret).contains(secret.compactCode))
        #expect(!dumped.contains(secret.compactCode))
    }

    @Test func injectedGeneratorIsDeterministicAndSeedsDiffer() {
        #expect(Fixtures.secret(seed: 7) == Fixtures.secret(seed: 7))
        #expect(Fixtures.secret(seed: 7) != Fixtures.secret(seed: 8))
    }
}
