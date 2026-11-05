import Foundation
import Testing
@testable import RemoteCore

struct FrameCodingTests {
    private func sampleFrame(payload: Data = Data([1, 2, 3, 4])) -> Frame {
        Frame(type: .videoFrame, flags: [.keyframe], timestampMicros: 123_456, payload: payload)
    }

    @Test func roundTripsSingleFrame() throws {
        // Arrange
        let frame = sampleFrame()
        var decoder = FrameDecoder()

        // Act
        let decoded = try decoder.append(FrameEncoder.encode(frame))

        // Assert
        #expect(decoded == [frame])
    }

    @Test func roundTripsEmptyPayload() throws {
        let frame = Frame(type: .keyframeRequest, timestampMicros: 1, payload: Data())
        var decoder = FrameDecoder()

        let decoded = try decoder.append(FrameEncoder.encode(frame))

        #expect(decoded == [frame])
    }

    @Test func decodesFrameDeliveredOneByteAtATime() throws {
        let frame = sampleFrame(payload: Data(repeating: 7, count: 50))
        var decoder = FrameDecoder()
        var decoded: [Frame] = []

        for byte in FrameEncoder.encode(frame) {
            decoded += try decoder.append(Data([byte]))
        }

        #expect(decoded == [frame])
    }

    @Test func decodesMultipleFramesInOneChunk() throws {
        let first = sampleFrame()
        let second = Frame(type: .videoConfig, timestampMicros: 9, payload: Data([9, 9]))
        var decoder = FrameDecoder()

        let decoded = try decoder.append(FrameEncoder.encode(first) + FrameEncoder.encode(second))

        #expect(decoded == [first, second])
    }

    @Test func keepsPartialFrameBufferedUntilComplete() throws {
        let encoded = FrameEncoder.encode(sampleFrame())
        var decoder = FrameDecoder()

        let early = try decoder.append(encoded.prefix(encoded.count - 1))
        let late = try decoder.append(encoded.suffix(1))

        #expect(early.isEmpty)
        #expect(late.count == 1)
    }

    @Test func rejectsUnknownMessageType() {
        var bytes = FrameEncoder.encode(sampleFrame())
        bytes[bytes.startIndex] = 0xFF
        var decoder = FrameDecoder()

        #expect(throws: FrameError.unknownType(0xFF)) {
            try decoder.append(bytes)
        }
    }

    @Test func rejectsOversizedPayloadBeforeBuffering() {
        var header = FrameEncoder.encode(Frame(type: .videoFrame, timestampMicros: 0, payload: Data()))
        let oversize = UInt32(FrameLimits.maxPayloadBytes + 1).bigEndian
        withUnsafeBytes(of: oversize) { header.replaceSubrange(10..<14, with: $0) }
        var decoder = FrameDecoder()

        #expect(throws: FrameError.payloadTooLarge(FrameLimits.maxPayloadBytes + 1)) {
            try decoder.append(header)
        }
    }

    @Test func staysFailedAfterProtocolError() throws {
        var bytes = FrameEncoder.encode(sampleFrame())
        bytes[bytes.startIndex] = 0xFF
        var decoder = FrameDecoder()
        _ = try? decoder.append(bytes)

        #expect(throws: FrameError.self) {
            try decoder.append(FrameEncoder.encode(sampleFrame()))
        }
    }
}
