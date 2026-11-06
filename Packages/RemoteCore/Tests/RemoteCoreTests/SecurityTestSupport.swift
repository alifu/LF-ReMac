import Foundation
@testable import RemoteCore

/// Deterministic generator for tests only (SplitMix64). Never use outside tests.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

enum Fixtures {
    static func fingerprint(_ byte: UInt8) -> DeviceFingerprint {
        // 32 bytes by construction.
        (try? DeviceFingerprint(bytes: Data(repeating: byte, count: DeviceFingerprint.byteCount)))
            ?? { preconditionFailure("fixture fingerprint") }()
    }

    static let host = fingerprint(0x11)
    static let phone = fingerprint(0x22)
    static let attacker = fingerprint(0x33)

    static func secret(seed: UInt64 = 1) -> PairingSecret {
        var generator = SeededGenerator(seed: seed)
        return PairingSecret.random(using: &generator)
    }
}
