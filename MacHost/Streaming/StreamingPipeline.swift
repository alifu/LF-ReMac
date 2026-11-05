import Foundation
import OSLog
import RemoteCore

extension H264EncoderSettings {
    func with(framesPerSecond: Int) -> H264EncoderSettings {
        H264EncoderSettings(
            averageBitRate: averageBitRate,
            framesPerSecond: framesPerSecond,
            keyframeIntervalSeconds: keyframeIntervalSeconds,
            peakBitRateRatio: peakBitRateRatio
        )
    }
}

/// Screen capture feeding the H.264 encoder; encoded output goes to `sink`.
/// One pipeline instance is created per client connection and torn down when the client leaves.
@MainActor
final class StreamingPipeline {
    typealias Sink = @Sendable (EncodedVideoEvent) -> Void

    private let logger = AppLog.logger(category: "pipeline")
    private var capturer: ScreenCapturer?
    private var encoder: H264Encoder?
    private var forwarding: Task<Void, Never>?

    var isRunning: Bool { capturer?.isRunning ?? false }

    func start(settings: CaptureSettings = .default, sink: @escaping Sink) async throws {
        guard !isRunning else { return }
        let size = CaptureSize.mainDisplay(maxLongSide: settings.maxLongSide)
        let encoder = try H264Encoder(
            width: size.width,
            height: size.height,
            settings: H264EncoderSettings.default.with(framesPerSecond: settings.framesPerSecond)
        )
        let forwarding = Task { for await event in encoder.events { sink(event) } }
        let capturer = ScreenCapturer()
        let logger = logger
        do {
            try await capturer.start(settings: settings) { sampleBuffer in
                do {
                    try encoder.encode(sampleBuffer)
                } catch {
                    logger.error("Encode failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        } catch {
            encoder.invalidate()
            forwarding.cancel()
            throw error
        }
        self.encoder = encoder
        self.capturer = capturer
        self.forwarding = forwarding
    }

    /// Makes the next encoded frame a keyframe (preceded by fresh parameter sets).
    func forceKeyframe() {
        encoder?.forceKeyframe()
    }

    func stop() async {
        await capturer?.stop()
        encoder?.invalidate()
        await forwarding?.value
        capturer = nil
        encoder = nil
        forwarding = nil
    }
}
