import AVFoundation
import CoreMedia
import Foundation
import os
import OSLog
import RemoteCore

/// Captured audio -> AAC -> wire frames. Runs on its own serial queue, which is also the queue
/// ScreenCaptureKit delivers audio on, so the encoder is only ever touched from there.
final class AudioStage: @unchecked Sendable {
    typealias Sink = @Sendable (Frame) -> Void

    let queue = DispatchQueue(label: "com.alifu.lfremac.audio", qos: .userInteractive)
    private let sink: Sink
    private let logger = AppLog.logger(category: "audio")
    private var encoder: AACEncoder?
    /// Cleared before capture is switched off, so buffers still in flight are not sent after the user said stop.
    private let enabled = OSAllocatedUnfairLock(initialState: false)

    init(sink: @escaping Sink) {
        self.sink = sink
    }

    func setEnabled(_ value: Bool) {
        enabled.withLock { $0 = value }
    }

    /// Forget the encoder, so the next audio starts with a fresh `audioConfig` (call when audio is switched on).
    func reset() {
        queue.async { self.encoder = nil }
    }

    /// Call on `queue`.
    func handle(_ sampleBuffer: CMSampleBuffer) {
        guard enabled.withLock({ $0 }), sampleBuffer.isValid, let pcm = AudioSampleBuffer.pcm(from: sampleBuffer) else { return }
        do {
            let encoder = try encoder(for: pcm.format)
            let micros = EncodedVideoEvent.micros(from: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            for packet in try encoder.encode(pcm, presentationTimeMicros: micros) {
                sink(try SessionMessageCoding.audioFrame(aac: packet.data, timestampMicros: packet.timestampMicros))
            }
        } catch {
            logger.error("Audio encode failed: \(String(describing: error), privacy: .public)")
        }
    }

    private var currentInputFormat: AVAudioFormat?

    private func encoder(for format: AVAudioFormat) throws -> AACEncoder {
        if let encoder, currentInputFormat == format { return encoder }
        let created = try AACEncoder(inputFormat: format)
        sink(try SessionMessageCoding.frame(for: created.config, timestampMicros: 0))
        encoder = created
        currentInputFormat = format
        return created
    }
}

enum AudioSampleBuffer {
    /// Copies the samples of a ScreenCaptureKit audio buffer into a PCM buffer.
    static func pcm(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}
