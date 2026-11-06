import CoreGraphics
import CoreMedia
import Foundation
import RemoteCore
import OSLog
import ScreenCaptureKit

enum ScreenCaptureError: Error, LocalizedError {
    case permissionDenied
    case noDisplayAvailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Screen Recording permission is required. Enable LF-ReMacHost in System Settings > Privacy & Security > Screen Recording, then relaunch."
        case .noDisplayAvailable:
            "No display was found to capture."
        }
    }
}

struct CaptureSettings: Sendable {
    static let `default` = CaptureSettings(framesPerSecond: 30, maxLongSide: 1920)

    let framesPerSecond: Int
    let maxLongSide: Int
}

/// Captures the main display with ScreenCaptureKit and hands raw frames to `onFrame`.
@MainActor
final class ScreenCapturer {
    typealias FrameHandler = @Sendable (CMSampleBuffer) -> Void

    private static let queueDepth = 3

    private let logger = AppLog.logger(category: "capture")
    private var stream: SCStream?
    private var output: StreamOutput?
    private var configuration: SCStreamConfiguration?

    var isRunning: Bool { stream != nil }

    /// Returns true if Screen Recording is already granted; otherwise triggers the system prompt.
    @discardableResult
    static func ensurePermission() -> Bool {
        CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
    }

    /// The display that will really be captured for `requested`: that display, or the main one when
    /// `requested` is nil. Throws if it is not available (e.g. just unplugged).
    static func resolveDisplayID(_ requested: CGDirectDisplayID?) async throws -> CGDirectDisplayID {
        guard ensurePermission() else { throw ScreenCaptureError.permissionDenied }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return try pickDisplay(requested, from: content.displays).displayID
    }

    private static func pickDisplay(_ requested: CGDirectDisplayID?, from displays: [SCDisplay]) throws -> SCDisplay {
        let wanted = requested ?? CGMainDisplayID()
        if let match = displays.first(where: { $0.displayID == wanted }) { return match }
        // Only an unspecified display may fall back; a specific one that vanished must not silently become another.
        if requested == nil, let first = displays.first { return first }
        throw ScreenCaptureError.noDisplayAvailable
    }

    /// - Parameter displayID: the display to capture; nil means the main display. A specific display that is gone throws.
    func start(
        displayID: CGDirectDisplayID? = nil,
        settings: CaptureSettings = .default,
        audio: AudioStage? = nil,
        onFrame: @escaping FrameHandler
    ) async throws {
        guard !isRunning else { return }
        guard Self.ensurePermission() else { throw ScreenCaptureError.permissionDenied }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let display = try Self.pickDisplay(displayID, from: content.displays)

        // SCDisplay.width/height are points; use real pixels so the encoder size always matches.
        let size = CaptureSize.display(display.displayID, maxLongSide: settings.maxLongSide)
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.framesPerSecond))
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.queueDepth = Self.queueDepth
        configuration.showsCursor = true
        // Audio is switched on later (`setAudioCapture`), only while the iPhone wants it.
        configuration.capturesAudio = false
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let output = StreamOutput(handler: onFrame, audio: audio, logger: logger)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        if let audio {
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: audio.queue)
        }
        try await stream.startCapture()

        self.stream = stream
        self.output = output
        self.configuration = configuration
        logger.info("Capture started \(size.width)x\(size.height) @ \(settings.framesPerSecond) fps")
    }

    /// Switches system-audio capture on or off while the stream runs.
    func setAudioCapture(_ enabled: Bool) async throws {
        guard let stream, let configuration, configuration.capturesAudio != enabled else { return }
        configuration.capturesAudio = enabled
        try await stream.updateConfiguration(configuration)
        // stop() may have run while this was suspended; the stream is gone then.
        guard self.stream === stream else { return }
        logger.info("Audio capture \(enabled ? "on" : "off", privacy: .public)")
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        self.output = nil
        self.configuration = nil
        do {
            try await stream.stopCapture()
            logger.info("Capture stopped")
        } catch {
            logger.error("Stopping capture failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Receives sample buffers on a private queue; kept separate so the capturer can stay main-actor isolated.
private final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.alifu.lfremac.capture", qos: .userInteractive)
    private let handler: ScreenCapturer.FrameHandler
    private let audio: AudioStage?
    private let logger: Logger

    init(handler: @escaping ScreenCapturer.FrameHandler, audio: AudioStage?, logger: Logger) {
        self.handler = handler
        self.audio = audio
        self.logger = logger
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            guard sampleBuffer.isValid, Self.isCompleteFrame(sampleBuffer) else { return }
            handler(sampleBuffer)
        case .audio:
            audio?.handle(sampleBuffer)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.error("Capture stream stopped: \(error.localizedDescription, privacy: .public)")
    }

    /// ScreenCaptureKit also emits idle/blank status buffers; only `.complete` frames carry pixels.
    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: rawStatus)
        else { return false }
        return status == .complete
    }
}
