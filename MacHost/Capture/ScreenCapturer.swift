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
            "Screen Recording permission is required. Enable LF-ReMac Host in System Settings > Privacy & Security > Screen Recording, then relaunch."
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

    var isRunning: Bool { stream != nil }

    /// Returns true if Screen Recording is already granted; otherwise triggers the system prompt.
    @discardableResult
    static func ensurePermission() -> Bool {
        CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
    }

    /// - Parameter displayID: the display to capture; nil (or one that is gone) means the main display.
    func start(
        displayID: CGDirectDisplayID? = nil,
        settings: CaptureSettings = .default,
        onFrame: @escaping FrameHandler
    ) async throws {
        guard !isRunning else { return }
        guard Self.ensurePermission() else { throw ScreenCaptureError.permissionDenied }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID })
            ?? content.displays.first(where: { $0.displayID == CGMainDisplayID() })
            ?? content.displays.first
        else { throw ScreenCaptureError.noDisplayAvailable }

        // SCDisplay.width/height are points; use real pixels so the encoder size always matches.
        let size = CaptureSize.display(display.displayID, maxLongSide: settings.maxLongSide)
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.framesPerSecond))
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.queueDepth = Self.queueDepth
        configuration.showsCursor = true

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let output = StreamOutput(handler: onFrame, logger: logger)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        try await stream.startCapture()

        self.stream = stream
        self.output = output
        logger.info("Capture started \(size.width)x\(size.height) @ \(settings.framesPerSecond) fps")
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        self.output = nil
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
    private let logger: Logger

    init(handler: @escaping ScreenCapturer.FrameHandler, logger: Logger) {
        self.handler = handler
        self.logger = logger
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, Self.isCompleteFrame(sampleBuffer) else { return }
        handler(sampleBuffer)
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
