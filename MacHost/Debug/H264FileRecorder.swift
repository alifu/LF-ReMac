import Foundation

enum H264FileRecorderError: Error, LocalizedError, Equatable {
    case cannotCreateFile(URL)
    case writeFailed(String)
    case closeFailed(String)
    case alreadyClosed

    var errorDescription: String? {
        switch self {
        case .cannotCreateFile(let url):
            "Could not create the recording file at \(url.path)."
        case .writeFailed(let message):
            "Writing the recording failed: \(message)"
        case .closeFailed(let message):
            "Saving the recording failed: \(message)"
        case .alreadyClosed:
            "The recording file has already been closed."
        }
    }
}

/// Appends raw Annex B bytes to a file, in call order. Call `close()` to surface flush errors.
actor H264FileRecorder {
    let url: URL
    private var handle: FileHandle?

    init(url: URL) throws {
        self.url = url
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw H264FileRecorderError.cannotCreateFile(url)
        }
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            throw H264FileRecorderError.cannotCreateFile(url)
        }
    }

    func append(_ data: Data) throws {
        guard let handle else { throw H264FileRecorderError.alreadyClosed }
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw H264FileRecorderError.writeFailed(error.localizedDescription)
        }
    }

    func close() throws {
        guard let handle else { throw H264FileRecorderError.alreadyClosed }
        self.handle = nil
        do {
            try handle.close()
        } catch {
            throw H264FileRecorderError.closeFailed(error.localizedDescription)
        }
    }
}
