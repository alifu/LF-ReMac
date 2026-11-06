import XCTest

/// Drives the Mac host in its dummy-data mode (`-screenshots`) and keeps README screenshots as attachments.
/// Run through `Tools/make-screenshots.sh`, which exports the attachments into docs/images.
final class ScreenshotTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-screenshots"]
        // The app draws its own windows into this folder (a screen capture would include the rest of the desktop).
        if let directory = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            app.launchArguments += ["-screenshot-dir", directory]
        }
        app.launch()
    }

    func testCaptureWindows() throws {
        // The app opens its demo windows by itself and writes the snapshots about 3 seconds later. Accessibility
        // lookup of the windows is unreliable for a menu-bar app, so this only waits; the script checks the files.
        _ = app.windows["Pair a New iPhone"].waitForExistence(timeout: 10)
        sleep(8)
    }
}
