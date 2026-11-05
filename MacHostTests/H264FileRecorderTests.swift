import Foundation
import Testing
@testable import MacHost

struct H264FileRecorderTests {
    @Test func writesChunksBackToBackInOrder() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "H264FileRecorderTests-\(UUID().uuidString).h264")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = Data([0x00, 0x00, 0x00, 0x01, 0x67])
        let second = Data([0x00, 0x00, 0x00, 0x01, 0x68, 0xEE])

        let recorder = try H264FileRecorder(url: url)
        try await recorder.append(first)
        try await recorder.append(second)
        try await recorder.close()

        let written = try Data(contentsOf: url)
        #expect(written == first + second)
    }

    @Test func throwsWhenPathIsUnwritable() {
        let url = URL(filePath: "/nonexistent-\(UUID().uuidString)/clip.h264")

        #expect(throws: H264FileRecorderError.cannotCreateFile(url)) {
            try H264FileRecorder(url: url)
        }
    }

    @Test func rejectsAppendAfterClose() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "H264FileRecorderTests-\(UUID().uuidString).h264")
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = try H264FileRecorder(url: url)
        try await recorder.close()

        await #expect(throws: H264FileRecorderError.alreadyClosed) {
            try await recorder.append(Data([0x00]))
        }
    }
}
