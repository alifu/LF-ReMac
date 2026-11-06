import AVFoundation
import Foundation
import RemoteCore

enum AACEncoderError: Error, Equatable {
    case unsupportedFormat
    case converterUnavailable
    case conversionFailed(String)
}

struct EncodedAudioPacket: Equatable, Sendable {
    let data: Data
    let timestampMicros: UInt64
}

/// The two setup bytes the iPhone needs to build an AAC-LC decoder (ISO 14496-3 AudioSpecificConfig).
enum AudioSpecificConfig {
    private static let aacLCObjectType: UInt16 = 2
    private static let sampleRates = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8_000]

    /// Nil for rates AAC has no index for, or for channel counts other than 1 or 2.
    static func aacLC(sampleRate: Int, channels: Int) -> Data? {
        guard let index = sampleRates.firstIndex(of: sampleRate), (1...2).contains(channels) else { return nil }
        let bits = aacLCObjectType << 11 | UInt16(index) << 7 | UInt16(channels) << 3
        return Data([UInt8(bits >> 8), UInt8(bits & 0xFF)])
    }
}

/// Turns captured PCM into raw AAC-LC access units (one per 1024 samples), at the input's sample rate.
/// Not thread-safe: use from one queue.
final class AACEncoder {
    static let frameSamples = 1024
    static let bitRate = 96_000
    /// Capture is expected to be contiguous; a bigger jump in timestamps starts a new timeline.
    private static let gapMicros: Int64 = 100_000

    let config: AudioConfig
    private let converter: AVAudioConverter
    private let sampleRate: Double
    private var anchorMicros: UInt64?
    private var fedFrames: Int64 = 0
    private var emittedPackets: Int64 = 0

    init(inputFormat: AVAudioFormat) throws(AACEncoderError) {
        let rate = Int(inputFormat.sampleRate)
        let channels = Int(inputFormat.channelCount)
        guard inputFormat.commonFormat == .pcmFormatFloat32,
              let specific = AudioSpecificConfig.aacLC(sampleRate: rate, channels: channels),
              [44_100, 48_000].contains(rate)
        else { throw .unsupportedFormat }

        var description = AudioStreamBasicDescription(
            mSampleRate: inputFormat.sampleRate, mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: UInt32(MPEG4ObjectID.AAC_LC.rawValue), mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(Self.frameSamples), mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0
        )
        guard let outputFormat = AVAudioFormat(streamDescription: &description),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { throw .converterUnavailable }
        converter.bitRate = Self.bitRate * channels / 2
        self.converter = converter
        sampleRate = inputFormat.sampleRate
        config = AudioConfig(
            codec: .aacLC, sampleRate: rate, channels: channels, frameSamples: Self.frameSamples,
            audioSpecificConfig: specific
        )
    }

    /// Returns the packets that became complete with this input (often none, sometimes two).
    func encode(_ pcm: AVAudioPCMBuffer, presentationTimeMicros: UInt64) throws(AACEncoderError) -> [EncodedAudioPacket] {
        reanchorIfNeeded(at: presentationTimeMicros)
        fedFrames += Int64(pcm.frameLength)

        var packets: [EncodedAudioPacket] = []
        var supplied = false
        while true {
            let output = AVAudioCompressedBuffer(
                format: converter.outputFormat, packetCapacity: 1, maximumPacketSize: converter.maximumOutputPacketSize
            )
            var failure: NSError?
            let status = converter.convert(to: output, error: &failure) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return pcm
            }
            switch status {
            case .haveData:
                if output.packetCount > 0, output.byteLength > 0 {
                    packets.append(EncodedAudioPacket(
                        data: Data(bytes: output.data, count: Int(output.byteLength)),
                        timestampMicros: nextTimestamp()
                    ))
                }
            case .inputRanDry, .endOfStream:
                return packets
            case .error:
                throw .conversionFailed(failure?.localizedDescription ?? "unknown")
            @unknown default:
                return packets
            }
        }
    }

    private func nextTimestamp() -> UInt64 {
        let base = anchorMicros ?? 0
        let offset = Double(emittedPackets * Int64(Self.frameSamples)) * 1_000_000 / sampleRate
        emittedPackets += 1
        return base + UInt64(offset.rounded())
    }

    private func reanchorIfNeeded(at micros: UInt64) {
        guard let anchor = anchorMicros else {
            anchorMicros = micros
            return
        }
        let expected = Int64(anchor) + Int64(Double(fedFrames) * 1_000_000 / sampleRate)
        guard abs(Int64(micros) - expected) > Self.gapMicros else { return }
        anchorMicros = micros
        fedFrames = 0
        emittedPackets = 0
    }
}
