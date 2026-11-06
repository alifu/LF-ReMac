import Foundation
import Testing
@testable import RemoteCore

struct DeviceFingerprintVerificationTests {
    @Test func formatsFirstEightBytesAsFourGroupsOfUppercaseHex() throws {
        let bytes = Data([0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6, 0x07, 0x18] + Array(repeating: 0xFF, count: 24))

        let fingerprint = try DeviceFingerprint(bytes: bytes)

        #expect(fingerprint.verificationCode == "A1B2-C3D4-E5F6-0718")
    }

    @Test func differentFingerprintsGiveDifferentCodes() throws {
        let first = try DeviceFingerprint(bytes: Data(repeating: 1, count: 32))
        let second = try DeviceFingerprint(bytes: Data(repeating: 2, count: 32))

        #expect(first.verificationCode != second.verificationCode)
    }
}
