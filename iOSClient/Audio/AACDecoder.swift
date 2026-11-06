import AVFoundation
import Foundation
import RemoteCore

enum AACDecoderError: Error, Equatable {
    case unsupportedConfig
    case emptyPacket
    case decodeFailed(String)
}

/// Raw AAC-LC access units -> Float32 PCM. Not thread-safe: use from one queue.
final class AACDecoder {
    let pcmFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let compressedFormat: AVAudioFormat

    init(config: AudioConfig) throws(AACDecoderError) {
        guard config.codec == .aacLC else { throw .unsupportedConfig }
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(config.sampleRate), mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: UInt32(MPEG4ObjectID.AAC_LC.rawValue), mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(config.frameSamples), mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(config.channels), mBitsPerChannel: 0, mReserved: 0
        )
        guard let compressed = AVAudioFormat(streamDescription: &description),
              let pcm = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Double(config.sampleRate),
                channels: AVAudioChannelCount(config.channels), interleaved: false),
              let converter = AVAudioConverter(from: compressed, to: pcm)
        else { throw .unsupportedConfig }
        compressedFormat = compressed
        pcmFormat = pcm
        self.converter = converter
    }

    func decode(_ packet: Data) throws(AACDecoderError) -> AVAudioPCMBuffer {
        guard !packet.isEmpty else { throw .emptyPacket }
        let input = AVAudioCompressedBuffer(format: compressedFormat, packetCapacity: 1, maximumPacketSize: packet.count)
        packet.withUnsafeBytes { input.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
        input.byteLength = UInt32(packet.count)
        input.packetCount = 1
        input.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))

        guard let output = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(compressedFormat.streamDescription.pointee.mFramesPerPacket)) else {
            throw .decodeFailed("no output buffer")
        }
        var supplied = false
        var failure: NSError?
        let status = converter.convert(to: output, error: &failure) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0 else {
            throw .decodeFailed(failure?.localizedDescription ?? "no samples")
        }
        return output
    }
}
