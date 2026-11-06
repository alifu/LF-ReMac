import AVFoundation
import Foundation
import RemoteCore

/// Turns received `Frame`s into pictures on an `AVSampleBufferDisplayLayer` (hardware decode).
///
/// Delta frames are only useful after a keyframe, so after any problem (frame arrives before config,
/// layer failure, layer not ready) the renderer skips video until the next keyframe and asks the
/// host for one - once per incident.
///
/// Not thread-safe: call `handle(_:)` from a single queue. `AVSampleBufferDisplayLayer` itself accepts
/// enqueues from any thread, so that queue does not need to be the main queue.
final class VideoRenderer: @unchecked Sendable {
    let displayLayer: AVSampleBufferDisplayLayer
    /// Called (on the handling queue) when the host should send a fresh keyframe.
    var onKeyframeNeeded: (@Sendable () -> Void)?
    /// Called (on the handling queue) when the host's picture size becomes known or changes.
    var onVideoSizeChange: (@Sendable (CGSize) -> Void)?

    private let logger = AppLog.logger(category: "renderer")
    private let statsCollector: StatsCollector?
    private var factory = SampleBufferFactory()
    private(set) var isAwaitingKeyframe = true
    private var hasRequestedKeyframe = false

    init(statsCollector: StatsCollector? = nil) {
        displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspect
        self.statsCollector = statsCollector
    }

    func handle(_ frame: Frame) {
        switch frame.type {
        case .videoConfig:
            handleConfig(frame.payload)
        case .videoFrame:
            handleVideo(frame)
        case .keyframeRequest, .input, .ping, .pairRequest, .pairResponse, .clientHello, .hostInfo, .selectDisplay:
            break
        }
    }

    /// Clears the picture and waits for a fresh start (e.g. after a reconnect).
    func reset() {
        displayLayer.flushAndRemoveImage()
        factory = SampleBufferFactory()
        isAwaitingKeyframe = true
        hasRequestedKeyframe = false
    }

    // MARK: - Handling

    private func handleConfig(_ payload: Data) {
        do {
            if try factory.ingestConfig(payload) {
                // New parameter sets (another display or size): delta frames still in flight were
                // encoded for the old picture, so wait for the keyframe that follows this config.
                displayLayer.flush()
                waitForKeyframe()
                hasRequestedKeyframe = false
                reportVideoSize()
            }
        } catch {
            logger.error("Bad video config: \(error.localizedDescription, privacy: .public)")
            waitForKeyframe()
        }
    }

    private func reportVideoSize() {
        guard let format = factory.formatDescription else { return }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        onVideoSizeChange?(CGSize(width: Int(dimensions.width), height: Int(dimensions.height)))
    }

    private func handleVideo(_ frame: Frame) {
        let isKeyframe = frame.flags.contains(.keyframe)
        if displayLayer.status == .failed {
            logger.error("Display layer failed: \(self.displayLayer.error?.localizedDescription ?? "unknown", privacy: .public)")
            displayLayer.flush()
            waitForKeyframe()
        }
        if isAwaitingKeyframe && !isKeyframe {
            requestKeyframeOnce()
            return
        }
        guard displayLayer.isReadyForMoreMediaData else {
            waitForKeyframe()
            requestKeyframeOnce()
            return
        }
        enqueue(frame, isKeyframe: isKeyframe)
    }

    private func enqueue(_ frame: Frame, isKeyframe: Bool) {
        do {
            let sampleBuffer = try factory.makeSampleBuffer(
                annexB: frame.payload,
                presentationTimeMicros: frame.timestampMicros,
                isKeyframe: isKeyframe
            )
            displayLayer.enqueue(sampleBuffer)
            statsCollector?.recordRenderedFrame()
            if isKeyframe {
                isAwaitingKeyframe = false
                hasRequestedKeyframe = false
            }
        } catch {
            logger.error("Dropping frame: \(error.localizedDescription, privacy: .public)")
            waitForKeyframe()
            requestKeyframeOnce()
        }
    }

    private func waitForKeyframe() {
        isAwaitingKeyframe = true
    }

    private func requestKeyframeOnce() {
        guard !hasRequestedKeyframe else { return }
        hasRequestedKeyframe = true
        onKeyframeNeeded?()
    }
}
