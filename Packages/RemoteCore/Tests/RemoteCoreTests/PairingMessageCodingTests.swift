import Foundation
import Testing
@testable import RemoteCore

struct PairingMessageCodingTests {
    private let proof = Data(repeating: 0xA5, count: 32)

    @Test func requestRoundTripsThroughAFrame() throws {
        let request = PairRequest(deviceName: "Ali's iPhone 👨‍👩‍👧", proof: proof)

        let frame = try PairingMessageCoding.frame(for: request, timestampMicros: 5)

        #expect(frame.type == .pairRequest)
        #expect(try PairingMessageCoding.request(from: frame) == request)
    }

    @Test func responseRoundTripsThroughAFrame() throws {
        let response = PairResponse(hostName: "Mac mini", proof: proof)

        let frame = try PairingMessageCoding.frame(for: response, timestampMicros: 5)

        #expect(frame.type == .pairResponse)
        #expect(try PairingMessageCoding.response(from: frame) == response)
    }

    @Test func newMessageTypesSurviveFraming() throws {
        let frame = try PairingMessageCoding.frame(for: PairRequest(deviceName: "x", proof: proof), timestampMicros: 1)
        var decoder = FrameDecoder()

        #expect(try decoder.append(FrameEncoder.encode(frame)) == [frame])
        #expect(MessageType(rawValue: 6) == .pairRequest)
        #expect(MessageType(rawValue: 7) == .pairResponse)
    }

    @Test func rejectsFramesOfOtherTypes() throws {
        let request = try PairingMessageCoding.frame(for: PairRequest(deviceName: "x", proof: proof), timestampMicros: 0)
        let asResponse = Frame(type: .pairResponse, timestampMicros: 0, payload: request.payload)

        #expect(throws: PairingMessageError.wrongMessageType) { try PairingMessageCoding.response(from: request) }
        #expect(throws: PairingMessageError.wrongMessageType) { try PairingMessageCoding.request(from: asResponse) }
        #expect(throws: PairingMessageError.wrongMessageType) {
            try PairingMessageCoding.request(from: Frame(type: .input, timestampMicros: 0, payload: request.payload))
        }
    }

    @Test(arguments: ["", "{}", "[]", "{\"deviceName\":1,\"proof\":\"\"}", "{\"deviceName\":\"x\",\"proof\":\"!!notbase64\"}", "\u{FF}\u{00}"])
    func rejectsMalformedPayloads(json: String) {
        let frame = Frame(type: .pairRequest, timestampMicros: 0, payload: Data(json.utf8))

        #expect(throws: PairingMessageError.malformedPayload) { try PairingMessageCoding.request(from: frame) }
    }

    @Test func rejectsOversizedPayloadBeforeDecoding() {
        let payload = Data(repeating: 0x20, count: PairingMessageCoding.maxPayloadBytes + 1)
        let frame = Frame(type: .pairRequest, timestampMicros: 0, payload: payload)

        #expect(throws: PairingMessageError.payloadTooLarge(payload.count)) { try PairingMessageCoding.request(from: frame) }
    }

    @Test(arguments: [0, 16, 31, 33, 64])
    func rejectsProofsThatAreNot32Bytes(length: Int) throws {
        let frame = try PairingMessageCoding.frame(for: PairRequest(deviceName: "x", proof: Data(count: length)), timestampMicros: 0)

        #expect(throws: PairingMessageError.invalidProofLength) { try PairingMessageCoding.request(from: frame) }
    }

    @Test(arguments: [
        "", "   ", String(repeating: "a", count: 65), "line\nbreak", "tab\there", "nul\u{0}", "bidi\u{202E}evil",
        "isolate\u{2066}x", "zero\u{200B}width", "private\u{E000}", "del\u{7F}", "sep\u{2028}x"
    ])
    func rejectsInvalidNames(name: String) throws {
        let request = try PairingMessageCoding.frame(for: PairRequest(deviceName: name, proof: proof), timestampMicros: 0)
        let response = try PairingMessageCoding.frame(for: PairResponse(hostName: name, proof: proof), timestampMicros: 0)

        #expect(throws: PairingMessageError.invalidName) { try PairingMessageCoding.request(from: request) }
        #expect(throws: PairingMessageError.invalidName) { try PairingMessageCoding.response(from: response) }
    }

    @Test(arguments: ["a", "Ali’s iPhone", String(repeating: "é", count: 64), "Büro-Mac (2)", "📱"])
    func acceptsReasonableNames(name: String) {
        #expect(DeviceName.isValid(name))
    }
}
