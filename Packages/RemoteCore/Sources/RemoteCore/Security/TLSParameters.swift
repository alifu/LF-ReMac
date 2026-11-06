import Foundation
import Network
import Security

public enum TLSConfigurationError: Error, Equatable, Sendable {
    case identityUnavailable
}

/// Builds Network.framework parameters for mutual TLS 1.3 with fingerprint pinning (no CA trust).
///
/// Both roles present `identity` and require the peer to present a certificate. The custom verify
/// block takes the peer's leaf certificate from the `sec_trust_t` under evaluation, computes its
/// `DeviceFingerprint` and accepts the handshake only if `isPeerAllowed` returns true. Certificate
/// chains, expiry and names are deliberately ignored: identity is the pinned public key, and the TLS
/// stack's CertificateVerify check proves the peer holds the matching private key.
///
/// Caveat for callers (TLS 1.3): a *client* reaches `.ready` before the server has judged the client
/// certificate, so a rejected client sees the connection fail/close right after `.ready`.
/// `isPeerAllowed` runs on a private serial queue and must be fast and thread-safe.
public enum TLSParameters {
    public typealias PeerPolicy = @Sendable (DeviceFingerprint) -> Bool

    private static let verifyQueue = DispatchQueue(label: "com.alifu.lfremac.tls-verify")

    public static func server(identity: DeviceIdentity, isPeerAllowed: @escaping PeerPolicy) throws(TLSConfigurationError) -> NWParameters {
        try parameters(identity: identity, isPeerAllowed: isPeerAllowed)
    }

    public static func client(identity: DeviceIdentity, isPeerAllowed: @escaping PeerPolicy) throws(TLSConfigurationError) -> NWParameters {
        try parameters(identity: identity, isPeerAllowed: isPeerAllowed)
    }

    /// The verified peer's fingerprint of a connection that reached `.ready`; nil before that or if
    /// the connection is not TLS. Use it for application-layer authorization (e.g. pairing proofs).
    public static func peerFingerprint(of connection: NWConnection) -> DeviceFingerprint? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
            return nil
        }
        return peerFingerprint(from: metadata.securityProtocolMetadata)
    }

    static func peerFingerprint(from metadata: sec_protocol_metadata_t) -> DeviceFingerprint? {
        var leaf: SecCertificate?
        let visited = sec_protocol_metadata_access_peer_certificate_chain(metadata) { certificate in
            if leaf == nil { leaf = sec_certificate_copy_ref(certificate).takeRetainedValue() }
        }
        guard visited, let leaf else { return nil }
        return try? DeviceFingerprint(certificate: leaf)
    }

    static func peerFingerprint(from trust: sec_trust_t) -> DeviceFingerprint? {
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
        guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate], let leaf = chain.first else {
            return nil
        }
        return try? DeviceFingerprint(certificate: leaf)
    }

    private static func parameters(identity: DeviceIdentity, isPeerAllowed: @escaping PeerPolicy) throws(TLSConfigurationError) -> NWParameters {
        guard let localIdentity = sec_identity_create(identity.secIdentity) else { throw .identityUnavailable }
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_set_local_identity(options, localIdentity)
        sec_protocol_options_set_peer_authentication_required(options, true)
        sec_protocol_options_set_verify_block(options, { _, trust, complete in
            // Fail closed: no certificate, unsupported key or unknown fingerprint all reject.
            let fingerprint = peerFingerprint(from: trust)
            complete(fingerprint.map(isPeerAllowed) ?? false)
        }, verifyQueue)
        return NWParameters(tls: tls, tcp: tcpOptions())
    }

    /// Same TCP tuning as the plaintext stream server: low latency and dead-peer detection.
    private static func tcpOptions() -> NWProtocolTCP.Options {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        return tcp
    }
}
