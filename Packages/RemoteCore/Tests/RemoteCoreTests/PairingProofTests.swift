import CryptoKit
import Foundation
import Testing
@testable import RemoteCore

struct PairingProofTests {
    private let secret = Fixtures.secret()

    @Test func matchesTheSpecifiedHMACConstruction() {
        let key = SymmetricKey(data: secret.bytes)
        let clientMessage = Data("lfremac-pair-v1-client".utf8) + Fixtures.phone.bytes + Fixtures.host.bytes
        let hostMessage = Data("lfremac-pair-v1-host".utf8) + Fixtures.host.bytes + Fixtures.phone.bytes

        #expect(PairingProof.client(secret: secret, client: Fixtures.phone, server: Fixtures.host)
            == Data(HMAC<SHA256>.authenticationCode(for: clientMessage, using: key)))
        #expect(PairingProof.host(secret: secret, client: Fixtures.phone, server: Fixtures.host)
            == Data(HMAC<SHA256>.authenticationCode(for: hostMessage, using: key)))
    }

    @Test func eachSideVerifiesTheOthersProof() {
        let clientProof = PairingProof.client(secret: secret, client: Fixtures.phone, server: Fixtures.host)
        let hostProof = PairingProof.host(secret: secret, client: Fixtures.phone, server: Fixtures.host)

        #expect(clientProof.count == 32)
        #expect(PairingProof.isValidClientProof(clientProof, secret: secret, client: Fixtures.phone, server: Fixtures.host))
        #expect(PairingProof.isValidHostProof(hostProof, secret: secret, client: Fixtures.phone, server: Fixtures.host))
    }

    @Test func clientProofDoesNotVerifyAsHostProofAndViceVersa() {
        let clientProof = PairingProof.client(secret: secret, client: Fixtures.phone, server: Fixtures.host)
        let hostProof = PairingProof.host(secret: secret, client: Fixtures.phone, server: Fixtures.host)

        #expect(clientProof != hostProof)
        #expect(!PairingProof.isValidHostProof(clientProof, secret: secret, client: Fixtures.phone, server: Fixtures.host))
        #expect(!PairingProof.isValidClientProof(hostProof, secret: secret, client: Fixtures.phone, server: Fixtures.host))
    }

    @Test func swappedFingerprintsDoNotVerify() {
        let proof = PairingProof.client(secret: secret, client: Fixtures.phone, server: Fixtures.host)

        #expect(!PairingProof.isValidClientProof(proof, secret: secret, client: Fixtures.host, server: Fixtures.phone))
    }

    @Test func wrongSecretDoesNotVerify() {
        let proof = PairingProof.client(secret: Fixtures.secret(seed: 99), client: Fixtures.phone, server: Fixtures.host)

        #expect(!PairingProof.isValidClientProof(proof, secret: secret, client: Fixtures.phone, server: Fixtures.host))
    }

    @Test(arguments: [0, 31, 33, 64])
    func wrongLengthProofsDoNotVerify(length: Int) {
        let proof = PairingProof.client(secret: secret, client: Fixtures.phone, server: Fixtures.host)
        let resized = Data(proof.prefix(length)) + Data(repeating: 0, count: max(0, length - proof.count))

        #expect(!PairingProof.isValidClientProof(resized, secret: secret, client: Fixtures.phone, server: Fixtures.host))
    }

    /// MITM terminates TLS on both sides with its own key: the phone sees `attacker` as server,
    /// the host sees `attacker` as client. Without the secret it can neither relay nor forge.
    @Test func manInTheMiddleCannotRelayOrForgeProofs() {
        let phoneProofSeenByAttacker = PairingProof.client(secret: secret, client: Fixtures.phone, server: Fixtures.attacker)

        // Relaying the phone's proof to the host fails: the host computes over (attacker, host).
        #expect(!PairingProof.isValidClientProof(
            phoneProofSeenByAttacker, secret: secret, client: Fixtures.attacker, server: Fixtures.host
        ))
        // Guessing a secret yields a proof for the wrong key.
        let forged = PairingProof.client(secret: Fixtures.secret(seed: 1234), client: Fixtures.attacker, server: Fixtures.host)
        #expect(!PairingProof.isValidClientProof(forged, secret: secret, client: Fixtures.attacker, server: Fixtures.host))
        // Relaying the host's response back to the phone fails too: the phone checks (phone, attacker).
        let hostProofSeenByAttacker = PairingProof.host(secret: secret, client: Fixtures.attacker, server: Fixtures.host)
        #expect(!PairingProof.isValidHostProof(
            hostProofSeenByAttacker, secret: secret, client: Fixtures.phone, server: Fixtures.attacker
        ))
    }
}
