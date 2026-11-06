import CoreGraphics
import Foundation
import OSLog
import RemoteCore

extension H264EncoderSettings {
    func with(averageBitRate: Int) -> H264EncoderSettings {
        H264EncoderSettings(
            averageBitRate: averageBitRate,
            framesPerSecond: framesPerSecond,
            keyframeIntervalSeconds: keyframeIntervalSeconds,
            peakBitRateRatio: peakBitRateRatio
        )
    }

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
    private var audioStage: AudioStage?
    private var encoder: H264Encoder?
    private var forwarding: Task<Void, Never>?
    private var ticking: Task<Void, Never>?
    private var bitrate = BitrateController(maxBitRate: H264EncoderSettings.default.averageBitRate)
    private let bitrateLogger = AppLog.logger(category: "bitrate")
    private let clock: @Sendable () -> Date
    private static let tickInterval = Duration.seconds(1)

    init(clock: @escaping @Sendable () -> Date = Date.init) {
        self.clock = clock
    }

    var isRunning: Bool { capturer?.isRunning ?? false }

    /// - Parameter displayID: display to stream; nil means the main display.
    /// - Parameter audioSink: receives `audioConfig` and `audioFrame`s once `setAudio(enabled: true)` is called.
    func start(
        displayID: CGDirectDisplayID? = nil, settings: CaptureSettings = .default,
        audioSink: @escaping AudioStage.Sink = { _ in }, sink: @escaping Sink
    ) async throws {
        guard !isRunning else { return }
        let size = CaptureSize.display(displayID ?? CGMainDisplayID(), maxLongSide: settings.maxLongSide)
        let encoder = try H264Encoder(
            width: size.width,
            height: size.height,
            settings: H264EncoderSettings.default.with(framesPerSecond: settings.framesPerSecond)
        )
        let forwarding = Task { for await event in encoder.events { sink(event) } }
        let capturer = ScreenCapturer()
        let audioStage = AudioStage(sink: audioSink)
        let logger = logger
        do {
            try await capturer.start(displayID: displayID, settings: settings, audio: audioStage) { sampleBuffer in
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
        self.audioStage = audioStage
        self.forwarding = forwarding
        bitrate.reset()
        startTicking()
    }

    /// Starts or stops capturing system audio. A restart begins with a fresh `audioConfig`.
    func setAudio(enabled: Bool) async {
        guard let capturer, let audioStage else { return }
        if enabled { audioStage.reset() }
        do {
            try await capturer.setAudioCapture(enabled)
        } catch {
            logger.error("Switching audio failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The client fell behind: lower the bitrate (debounced by the controller).
    func reportCongestion() {
        guard encoder != nil else { return }
        applyBitrate(.congested(at: clock()))
    }

    private func startTicking() {
        ticking?.cancel()
        ticking = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                guard !Task.isCancelled, let self else { return }
                self.applyBitrate(.tick(at: self.clock()))
            }
        }
    }

    private func applyBitrate(_ event: BitrateController.Event) {
        guard let encoder else { return }
        let previous = bitrate.targetBitRate
        bitrate.handle(event)
        let target = bitrate.targetBitRate
        guard target != previous else { return }
        do {
            try encoder.setBitrate(target)
            bitrateLogger.notice("Bitrate \(previous) -> \(target) bps")
        } catch {
            bitrateLogger.error("Setting bitrate failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Makes the next encoded frame a keyframe (preceded by fresh parameter sets).
    func forceKeyframe() {
        encoder?.forceKeyframe()
    }

    func stop() async {
        ticking?.cancel()
        ticking = nil
        await capturer?.stop()
        encoder?.invalidate()
        await forwarding?.value
        capturer = nil
        audioStage = nil
        encoder = nil
        forwarding = nil
    }
}
