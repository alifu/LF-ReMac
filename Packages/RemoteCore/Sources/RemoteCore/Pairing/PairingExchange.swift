import Foundation

public enum PairingResponseError: Error, Equatable, Sendable {
    /// The frame was not a well-formed `pairResponse`.
    case malformed(PairingMessageError)
    /// The host's proof does not verify for this secret and these two TLS fingerprints.
    case invalidHostProof
}

/// The pure, I/O-free parts of the pairing handshake shared by the iPhone client and the Mac host.
///
/// Fingerprints passed here must be the ones observed in the TLS handshake of the connection the
/// messages travel on (`TLSParameters.peerFingerprint(of:)` and the local identity), never values a
/// peer claims, so the proofs are bound to that exact TLS session.
public enum PairingExchange {
    /// Pairing messages are tiny; nothing larger is ever buffered from an unauthenticated peer.
    public static let maxPayloadBytes = PairingMessageCoding.maxPayloadBytes
    /// Largest number of bytes worth reading at once on a pairing connection.
    public static let maxReadBytes = FrameLimits.headerBytes + maxPayloadBytes

    /// Host side: decoder for a not-yet-paired peer. Anything but a small `pairRequest` fails.
    public static func requestDecoder() -> FrameDecoder {
        FrameDecoder(maxPayloadBytes: maxPayloadBytes, allowedTypes: [.pairRequest])
    }

    /// Client side: decoder for the reply on a pairing connection.
    public static func responseDecoder() -> FrameDecoder {
        FrameDecoder(maxPayloadBytes: maxPayloadBytes, allowedTypes: [.pairResponse])
    }

    /// iPhone -> Mac: `pairRequest` carrying `PairingProof.client(...)`.
    public static func requestFrame(
        secret: PairingSecret,
        clientFingerprint: DeviceFingerprint,
        serverFingerprint: DeviceFingerprint,
        deviceName: String
    ) throws(PairingMessageError) -> Frame {
        guard DeviceName.isValid(deviceName) else { throw .invalidName }
        let proof = PairingProof.client(secret: secret, client: clientFingerprint, server: serverFingerprint)
        return try PairingMessageCoding.frame(for: PairRequest(deviceName: deviceName, proof: proof), timestampMicros: 0)
    }

    /// Mac -> iPhone: `pairResponse` carrying the host proof from a successful `PairingSession.attempt`.
    public static func responseFrame(hostName: String, hostProof: Data) throws(PairingMessageError) -> Frame {
        guard DeviceName.isValid(hostName) else { throw .invalidName }
        return try PairingMessageCoding.frame(for: PairResponse(hostName: hostName, proof: hostProof), timestampMicros: 0)
    }

    /// iPhone side: decodes the reply and checks the host proof in constant time. Only a response
    /// that passes this may lead to the host's fingerprint being stored.
    public static func verifiedResponse(
        _ frame: Frame,
        secret: PairingSecret,
        clientFingerprint: DeviceFingerprint,
        serverFingerprint: DeviceFingerprint
    ) throws(PairingResponseError) -> PairResponse {
        let response: PairResponse
        do {
            response = try PairingMessageCoding.response(from: frame)
        } catch {
            throw .malformed(error)
        }
        guard PairingProof.isValidHostProof(
            response.proof, secret: secret, client: clientFingerprint, server: serverFingerprint
        ) else {
            throw .invalidHostProof
        }
        return response
    }
}
