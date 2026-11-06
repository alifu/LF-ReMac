import CryptoKit
import Foundation

/// Pairing proofs (plan, Phase 4): HMAC-SHA256 keyed with the one-time secret over a role label and
/// both TLS fingerprints, so a proof is bound to *this* TLS session's two keys and to one direction:
/// - client: HMAC(secret, "lfremac-pair-v1-client" || clientFP || serverFP)
/// - host:   HMAC(secret, "lfremac-pair-v1-host"   || serverFP || clientFP)
/// A man-in-the-middle terminating TLS has a different fingerprint on at least one side, so it
/// cannot reuse a proof and cannot forge one without the secret. Verification is constant time.
public enum PairingProof {
    public static let byteCount = 32
    static let clientLabel = Data("lfremac-pair-v1-client".utf8)
    static let hostLabel = Data("lfremac-pair-v1-host".utf8)

    public static func client(secret: PairingSecret, client: DeviceFingerprint, server: DeviceFingerprint) -> Data {
        mac(secret, clientLabel + client.bytes + server.bytes)
    }

    public static func host(secret: PairingSecret, client: DeviceFingerprint, server: DeviceFingerprint) -> Data {
        mac(secret, hostLabel + server.bytes + client.bytes)
    }

    public static func isValidClientProof(
        _ proof: Data, secret: PairingSecret, client: DeviceFingerprint, server: DeviceFingerprint
    ) -> Bool {
        verify(proof, secret, clientLabel + client.bytes + server.bytes)
    }

    public static func isValidHostProof(
        _ proof: Data, secret: PairingSecret, client: DeviceFingerprint, server: DeviceFingerprint
    ) -> Bool {
        verify(proof, secret, hostLabel + server.bytes + client.bytes)
    }

    private static func mac(_ secret: PairingSecret, _ message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: secret.bytes)))
    }

    private static func verify(_ proof: Data, _ secret: PairingSecret, _ message: Data) -> Bool {
        // The length is public (always 32); the comparison of the bytes is constant time.
        guard proof.count == byteCount else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: message, using: SymmetricKey(data: secret.bytes))
    }
}
