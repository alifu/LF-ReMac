import Foundation
import Testing
@testable import RemoteCore

struct AppLogTests {
    @Test func usesFallbackSubsystemWhenBundleHasNoIdentifier() throws {
        // Arrange
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try #require(Bundle(url: directory))

        // Act
        let subsystem = AppLog.subsystem(for: bundle)

        // Assert
        #expect(subsystem == AppLog.fallbackSubsystem)
    }
}
