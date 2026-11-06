#if DEBUG
import CoreGraphics
import Foundation
import OSLog
import RemoteCore

enum PipelineRecorderError: Error, LocalizedError, Equatable {
    case invalidDuration(Int)
    case noMoviesDirectory

    var errorDescription: String? {
        switch self {
        case .invalidDuration(let seconds):
            "Recording duration must be at least 1 second (got \(seconds))."
        case .noMoviesDirectory:
            "The Movies folder could not be found to save the recording."
        }
    }
}

/// Debug helper: captures the main display through the real capture + encode pipeline
/// and saves the Annex B output as a raw `.h264` file playable by ffplay or VLC.
@MainActor
final class PipelineRecorder {
    private let logger = AppLog.logger(category: "debug-recorder")

    /// Records `seconds` of the main display and returns the saved file's URL.
    func record(seconds: Int = 10) async throws -> URL {
        guard seconds > 0 else { throw PipelineRecorderError.invalidDuration(seconds) }
        guard ScreenCapturer.ensurePermission() else { throw ScreenCaptureError.permissionDenied }

        let size = Self.captureSize()
        let url = try Self.outputURL(for: Date())
        let encoder = try H264Encoder(width: size.width, height: size.height)
        let file = try H264FileRecorder(url: url)
        let writer = Task { try await Self.drain(encoder.events, into: file, logger: logger) }

        let capturer = ScreenCapturer()
        var captureFailure: Error?
        do {
            try await capturer.start(onFrame: Self.frameHandler(for: encoder, logger: logger))
            try await Task.sleep(for: .seconds(seconds))
        } catch {
            captureFailure = error
        }
        await capturer.stop()
        encoder.flush()
        encoder.invalidate()

        let writeResult = await writer.result
        if case .failure(let error) = writeResult {
            logger.error("Writing debug recording failed: \(error.localizedDescription, privacy: .public)")
        }
        if let captureFailure { throw captureFailure }
        try writeResult.get()
        logger.info("Debug recording saved to \(url.lastPathComponent, privacy: .public)")
        return url
    }

    /// Same dimensions ScreenCapturer will be asked for.
    private nonisolated static func captureSize() -> CaptureSize {
        CaptureSize.mainDisplay(maxLongSide: CaptureSettings.default.maxLongSide)
    }

    private nonisolated static func outputURL(for date: Date) throws -> URL {
        guard let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first else {
            throw PipelineRecorderError.noMoviesDirectory
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return movies.appending(path: "LF-ReMac-debug-\(formatter.string(from: date)).h264")
    }

    /// Runs on the capture queue, so it must not touch main-actor state.
    private nonisolated static func frameHandler(
        for encoder: H264Encoder,
        logger: Logger
    ) -> ScreenCapturer.FrameHandler {
        { sampleBuffer in
            do {
                try encoder.encode(sampleBuffer)
            } catch {
                logger.error("Encoding captured frame failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Appends every encoded event until the encoder finishes, then closes the file.
    private nonisolated static func drain(
        _ events: AsyncStream<EncodedVideoEvent>,
        into file: H264FileRecorder,
        logger: Logger
    ) async throws {
        do {
            for await event in events {
                try await file.append(event.annexBBytes)
            }
        } catch {
            do {
                try await file.close()
            } catch {
                logger.error("Closing debug recording failed: \(error.localizedDescription, privacy: .public)")
            }
            throw error
        }
        try await file.close()
    }
}

private extension EncodedVideoEvent {
    var annexBBytes: Data {
        switch self {
        case .config(let data), .frame(let data, _, _):
            data
        }
    }
}
#endif
