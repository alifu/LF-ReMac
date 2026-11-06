import UIKit
import XCTest

/// Drives the app in its dummy-data mode (`-screenshots`) and saves README screenshots.
/// Run through `Tools/make-screenshots.sh`; files go to `$SCREENSHOT_DIR` (and are kept as test attachments).
final class ScreenshotTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-screenshots"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
    }

    func testCaptureHostListAndStream() throws {
        let host = app.buttons["Mac mini"]
        XCTAssertTrue(host.waitForExistence(timeout: 10), "dummy Mac should be listed")
        save("ios-hosts")

        host.tap()
        let disconnect = app.buttons["Disconnect from Mac mini"]
        if !disconnect.waitForExistence(timeout: 10) {
            save("ios-failure")
            XCTFail("stream screen should open. Buttons: \(app.buttons.allElementsBoundByIndex.map { $0.label })")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["30 frames per second, 5.8 megabits per second, round trip 12 milliseconds"].waitForExistence(timeout: 5))
        sleep(1)  // let the rotation settle
        save("ios-stream")
    }

    private func save(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let image = upright(shot.image)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try? image.pngData()?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }

    /// A screenshot carries an orientation flag that PNG export ignores, so landscape came out sideways.
    /// Redrawing bakes the orientation into the pixels.
    private func upright(_ image: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}
