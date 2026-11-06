import Foundation
import Testing
@testable import RemoteCore

struct PairingExchangeTests {
    private let secret = Fixtures.secret(seed: 7)

    @Test func requestFrameCarriesAClientProofTheHostSessionAccepts() throws {
        let frame = try PairingExchange.requestFrame(
            secret: secret, clientFingerprint: Fixtures.phone, serverFingerprint: Fixtures.host, deviceName: "Ali's iPhone"
        )
        let request = try PairingMessageCoding.request(from: frame)
        let session = PairingSession.start(now: Date(timeIntervalSince1970: 0), secret: secret)

        let outcome = session.attempt(
            proof: request.proof, clientFingerprint: Fixtures.phone, serverFingerprint: Fixtures.host,
            deviceName: request.deviceName, now: Date(timeIntervalSince1970: 1)
        )

        #expect(frame.type == .pairRequest)
        #expect(request.deviceName == "Ali's iPhone")
        #expect(throws: Never.self) { try outcome.result.get() }
    }

    @Test func requestFrameRefusesAnInvalidDeviceName() {
        #expect(throws: PairingMessageError.invalidName) {
            try PairingExchange.requestFrame(
                secret: secret, clientFingerprint: Fixtures.phone, serverFingerprint: Fixtures.host, deviceName: "bad\nname"
            )
        }
    }

    @Test func requestDecoderRejectsAnythingButSmallPairRequests() throws {
        var video = PairingExchange.requestDecoder()
        #expect(throws: FrameError.disallowedType(.videoFrame)) {
            try video.append(Data([MessageType.videoFrame.rawValue]))
        }
        var oversized = PairingExchange.requestDecoder()
        let big = Frame(type: .pairRequest, timestampMicros: 0, payload: Data(count: PairingExchange.maxPayloadBytes + 1))
        #expect(throws: FrameError.payloadTooLarge(PairingExchange.maxPayloadBytes + 1)) {
            try oversized.append(FrameEncoder.encode(big).prefix(FrameLimits.headerBytes))
        }
    }

    @Test func validHostProofIsAccepted() throws {
        let frame = try responseFrame(proof: PairingProof.host(secret: secret, client: Fixtures.phone, server: Fixtures.host))

        let response = try PairingExchange.verifiedResponse(
            frame, secret: secret, clientFingerprint: Fixtures.phone, serverFingerprint: Fixtures.host
        )

        #expect(response.hostName == "Mac mini")
    }

    @Test func hostProofMadeWithAnotherSecretIsRejected() throws {
        let other = Fixtures.secret(seed: 8)
        let frame = try responseFrame(proof: PairingProof.host(secret: other, client: Fixtures.phone, server: Fixtures.host))

        #expect(throws: PairingResponseError.invalidHostProof) {
            try PairingExchange.verifiedResponse(frame, secret: secret, clientFingerprint: Fixtures.phone, serverFingerprint: Fixtures.host)
        }
    }

    @Test func hostProofForAnotherServerKeyIsRejected() throws {
        // A MITM relaying the real host's proof presents its own TLS key, so the fingerprints differ.
        let frame = try responseFrame(proof: PairingProof.host(secret: secret, client: Fixtures.phone, server: Fixtures.host))

        #expect(throws: PairingResponseError.invalidHostProof) {
            try PairingExchange.verifiedResponse(frame, secret: secret, clientFingerprint: Fixtures.phone, serverFingerprint: Fixtures.attacker)
        }
    }

    @Test func clientProofEchoedBackAsHostProofIsRejected() throws {
        let reflected = PairingProof.client(secret: secret, client: Fixtures.phone, server: Fixtures.host)
        let frame = try responseFrame(proof: reflected)

        #expect(throws: PairingResponseError.invalidHostProof) {
            try PairingExchange.verifiedResponse(frame, secret: secret, clientFingerprint: Fixtures.phone, serverFingerprint: Fixtures.host)
        }
    }

    @Test func wrongFrameTypeIsMalformed() {
        let frame = Frame(type: .pairRequest, timestampMicros: 0, payload: Data())

        #expect(throws: PairingResponseError.malformed(.wrongMessageType)) {
            try PairingExchange.verifiedResponse(frame, secret: secret, clientFingerprint: Fixtures.phone, serverFingerprint: Fixtures.host)
        }
    }

    @Test func responseFrameRefusesAnInvalidHostName() {
        #expect(throws: PairingMessageError.invalidName) {
            try PairingExchange.responseFrame(hostName: "", hostProof: Data(count: PairingProof.byteCount))
        }
    }

    private func responseFrame(proof: Data) throws -> Frame {
        try PairingExchange.responseFrame(hostName: "Mac mini", hostProof: proof)
    }
}
