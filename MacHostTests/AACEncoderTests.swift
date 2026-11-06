import AVFoundation
import Foundation
import RemoteCore
import Testing
@testable import MacHost

struct AACEncoderTests {
    private static let chunkFrames: AVAudioFrameCount = 480

    private func format(interleaved: Bool = false) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: interleaved)!
    }

    private func sine(_ format: AVAudioFormat, frames: AVAudioFrameCount, startingAt offset: Int) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channels = Int(format.channelCount)
        let samples = buffer.floatChannelData!
        for frame in 0..<Int(frames) {
            let value = Float(sin(2 * Double.pi * 440 * Double(offset + frame) / 48_000)) * 0.5
            for channel in 0..<channels {
                if format.isInterleaved {
                    samples[0][frame * channels + channel] = value
                } else {
                    samples[channel][frame] = value
                }
            }
        }
        return buffer
    }

    private func encodeOneSecond(_ encoder: AACEncoder, format: AVAudioFormat, startMicros: UInt64 = 1_000_000) throws -> [EncodedAudioPacket] {
        var packets: [EncodedAudioPacket] = []
        let chunks = 100
        for index in 0..<chunks {
            let micros = startMicros + UInt64(index) * 10_000
            packets += try encoder.encode(
                sine(format, frames: Self.chunkFrames, startingAt: index * Int(Self.chunkFrames)),
                presentationTimeMicros: micros
            )
        }
        return packets
    }

    @Test func audioSpecificConfigForAACLCStereo48k() {
        #expect(AudioSpecificConfig.aacLC(sampleRate: 48_000, channels: 2) == Data([0x11, 0x90]))
        #expect(AudioSpecificConfig.aacLC(sampleRate: 44_100, channels: 2) == Data([0x12, 0x10]))
        #expect(AudioSpecificConfig.aacLC(sampleRate: 48_000, channels: 1) == Data([0x11, 0x88]))
    }

    @Test func audioSpecificConfigRejectsUnsupportedFormats() {
        #expect(AudioSpecificConfig.aacLC(sampleRate: 12_345, channels: 2) == nil)
        #expect(AudioSpecificConfig.aacLC(sampleRate: 48_000, channels: 0) == nil)
        #expect(AudioSpecificConfig.aacLC(sampleRate: 48_000, channels: 3) == nil)
    }

    @Test func configMatchesWhatTheIPhoneValidates() throws {
        let encoder = try AACEncoder(inputFormat: format())

        let frame = try SessionMessageCoding.frame(for: encoder.config, timestampMicros: 0)

        #expect(try SessionMessageCoding.audioConfig(from: frame) == encoder.config)
        #expect(encoder.config.frameSamples == 1024)
    }

    @Test func oneSecondOfPlanarAudioBecomesAboutFortySevenPackets() throws {
        let encoder = try AACEncoder(inputFormat: format())

        let packets = try encodeOneSecond(encoder, format: format())

        #expect((44...48).contains(packets.count))
        #expect(packets.allSatisfy { !$0.data.isEmpty && $0.data.count <= SessionMessageCoding.maxAudioFrameBytes })
    }

    @Test func interleavedInputWorksToo() throws {
        let interleaved = format(interleaved: true)
        let encoder = try AACEncoder(inputFormat: interleaved)

        let packets = try encodeOneSecond(encoder, format: interleaved)

        #expect((44...48).contains(packets.count))
    }

    @Test func packetsAreAcceptedAsAudioFrames() throws {
        let encoder = try AACEncoder(inputFormat: format())
        let packets = try encodeOneSecond(encoder, format: format())

        let frame = try SessionMessageCoding.audioFrame(aac: packets[0].data, timestampMicros: packets[0].timestampMicros)

        #expect(try SessionMessageCoding.audioAccessUnit(from: frame) == packets[0].data)
    }

    @Test func timestampsAdvanceByOnePacketDurationFromTheFirstBuffer() throws {
        let encoder = try AACEncoder(inputFormat: format())

        let packets = try encodeOneSecond(encoder, format: format(), startMicros: 5_000_000)

        #expect(packets[0].timestampMicros == 5_000_000)
        let step = Double(packets[1].timestampMicros - packets[0].timestampMicros)
        #expect(abs(step - 21_333) < 2)
        for pair in zip(packets, packets.dropFirst()) {
            #expect(pair.1.timestampMicros > pair.0.timestampMicros)
        }
    }

    @Test func aGapInCaptureStartsANewTimeline() throws {
        let encoder = try AACEncoder(inputFormat: format())
        _ = try encodeOneSecond(encoder, format: format(), startMicros: 1_000_000)

        // Capture paused (silence is not delivered) and came back 10 s later.
        let later = try encodeOneSecond(encoder, format: format(), startMicros: 11_000_000)

        #expect(later.first.map { $0.timestampMicros >= 11_000_000 - 25_000 } == true)
    }

    @Test func rejectsFormatsTheIPhoneCannotPlay() {
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 22_050, channels: 1, interleaved: false)!

        #expect(throws: AACEncoderError.self) { try AACEncoder(inputFormat: mono) }
    }
}
