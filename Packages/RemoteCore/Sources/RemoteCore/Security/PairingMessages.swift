import Foundation

/// iPhone -> Mac, first message on a pairing connection.
public struct PairRequest: Codable, Equatable, Sendable {
    public let deviceName: String
    /// `PairingProof.client(...)`, 32 bytes.
    public let proof: Data

    public init(deviceName: String, proof: Data) {
        self.deviceName = deviceName
        self.proof = proof
    }
}

/// Mac -> iPhone, sent only after the request's proof verified.
public struct PairResponse: Codable, Equatable, Sendable {
    public let hostName: String
    /// `PairingProof.host(...)`, 32 bytes.
    public let proof: Data

    public init(hostName: String, proof: Data) {
        self.hostName = hostName
        self.proof = proof
    }
}

public enum PairingMessageError: Error, Equatable, Sendable {
    case wrongMessageType
    case payloadTooLarge(Int)
    case malformedPayload
    case invalidName
    case invalidProofLength
}

/// JSON coding of pairing messages. Decoding treats the payload as untrusted (it arrives from a
/// not-yet-paired peer): size cap first, then shape, then field validation.
public enum PairingMessageCoding {
    /// Comfortably above a valid message (64-char name, 44-char base64 proof, JSON overhead).
    public static let maxPayloadBytes = 1024

    public static func frame(for request: PairRequest, timestampMicros: UInt64) throws(PairingMessageError) -> Frame {
        Frame(type: .pairRequest, timestampMicros: timestampMicros, payload: try encode(request))
    }

    public static func frame(for response: PairResponse, timestampMicros: UInt64) throws(PairingMessageError) -> Frame {
        Frame(type: .pairResponse, timestampMicros: timestampMicros, payload: try encode(response))
    }

    public static func request(from frame: Frame) throws(PairingMessageError) -> PairRequest {
        let request: PairRequest = try decode(frame, expecting: .pairRequest)
        try validate(name: request.deviceName, proof: request.proof)
        return request
    }

    public static func response(from frame: Frame) throws(PairingMessageError) -> PairResponse {
        let response: PairResponse = try decode(frame, expecting: .pairResponse)
        try validate(name: response.hostName, proof: response.proof)
        return response
    }

    // MARK: Private

    private static func encode<T: Encodable>(_ message: T) throws(PairingMessageError) -> Data {
        do {
            return try JSONEncoder().encode(message)
        } catch {
            throw .malformedPayload
        }
    }

    private static func decode<T: Decodable>(_ frame: Frame, expecting type: MessageType) throws(PairingMessageError) -> T {
        guard frame.type == type else { throw .wrongMessageType }
        guard frame.payload.count <= maxPayloadBytes else { throw .payloadTooLarge(frame.payload.count) }
        do {
            return try JSONDecoder().decode(T.self, from: frame.payload)
        } catch {
            throw .malformedPayload
        }
    }

    private static func validate(name: String, proof: Data) throws(PairingMessageError) {
        guard DeviceName.isValid(name) else { throw .invalidName }
        guard proof.count == PairingProof.byteCount else { throw .invalidProofLength }
    }
}

/// Rules for peer-supplied display names (shown in pairing UI and the paired-devices list).
public enum DeviceName {
    public static let maxLength = 64
    private static let zeroWidthJoiner: Unicode.Scalar = "\u{200D}"

    /// 1...64 characters, not only whitespace, no control/format/separator/private-use characters
    /// (blocks newlines and bidi overrides that could spoof UI). Emoji ZWJ sequences are allowed.
    public static func isValid(_ name: String) -> Bool {
        guard (1...maxLength).contains(name.count), name.unicodeScalars.count <= maxLength * 4 else { return false }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return name.unicodeScalars.allSatisfy(isAllowed)
    }

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .unassigned:
            return false
        case .format:
            return scalar == zeroWidthJoiner
        default:
            return true
        }
    }
}
