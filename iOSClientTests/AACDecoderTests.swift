import AVFoundation
import RemoteCore
import Testing
@testable import iOSClient

struct AACDecoderTests {
    private let config = AudioConfig(
        codec: .aacLC, sampleRate: 48_000, channels: 2, frameSamples: 1024, audioSpecificConfig: Data([0x11, 0x90])
    )

    /// Makes real AAC-LC packets the way the Mac does.
    private func encodedPackets(seconds: Double) throws -> [Data] {
        let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: UInt32(MPEG4ObjectID.AAC_LC.rawValue),
            mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        let output = AVAudioFormat(streamDescription: &description)!
        let converter = AVAudioConverter(from: input, to: output)!
        let frames = AVAudioFrameCount(48_000 * seconds)
        let pcm = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: frames)!
        pcm.frameLength = frames
        for channel in 0..<2 {
            for index in 0..<Int(frames) {
                pcm.floatChannelData![channel][index] = Float(sin(2 * Double.pi * 440 * Double(index) / 48_000)) * 0.5
            }
        }
        var packets: [Data] = []
        var supplied = false
        while true {
            let buffer = AVAudioCompressedBuffer(format: output, packetCapacity: 1, maximumPacketSize: converter.maximumOutputPacketSize)
            var error: NSError?
            let status = converter.convert(to: buffer, error: &error) { _, inputStatus in
                if supplied { inputStatus.pointee = .noDataNow; return nil }
                supplied = true
                inputStatus.pointee = .haveData
                return pcm
            }
            guard status == .haveData else { break }
            packets.append(Data(bytes: buffer.data, count: Int(buffer.byteLength)))
        }
        return packets
    }

    @Test func decodesAPacketToAThousandAndTwentyFourSamples() throws {
        let packets = try encodedPackets(seconds: 0.5)
        let decoder = try AACDecoder(config: config)

        let pcm = try decoder.decode(packets[3])

        #expect(pcm.frameLength == 1024)
        #expect(pcm.format.channelCount == 2)
        #expect(pcm.format.sampleRate == 48_000)
    }

    @Test func decodedToneIsNotSilence() throws {
        let packets = try encodedPackets(seconds: 0.5)
        let decoder = try AACDecoder(config: config)
        var peak: Float = 0

        for packet in packets.prefix(10) {
            let pcm = try decoder.decode(packet)
            for index in 0..<Int(pcm.frameLength) { peak = max(peak, abs(pcm.floatChannelData![0][index])) }
        }

        #expect(peak > 0.2)
    }

    @Test func garbageDoesNotCrashAndIsReported() throws {
        let decoder = try AACDecoder(config: config)

        #expect(throws: AACDecoderError.self) { try decoder.decode(Data()) }
    }
}
