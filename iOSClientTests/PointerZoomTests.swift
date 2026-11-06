import CoreGraphics
import Foundation
import RemoteCore
import Testing
@testable import iOSClient

@MainActor
struct PointerZoomTests {
    private final class Recorder {
        var events: [InputEvent] = []
        var zooms: [ViewZoom] = []
    }

    private func makeController(mode: PointerController.Mode) -> (PointerController, Recorder) {
        let recorder = Recorder()
        let controller = PointerController(mode: mode) { recorder.events.append($0) }
        controller.viewport = VideoViewport(viewSize: CGSize(width: 400, height: 200), videoSize: CGSize(width: 1600, height: 800))
        controller.onZoomChange = { recorder.zooms.append($0) }
        return (controller, recorder)
    }

    @Test func pinchingZoomsInAndReportsTheChange() {
        let (controller, recorder) = makeController(mode: .direct)

        controller.pinch(by: 2, around: CGPoint(x: 200, y: 100))

        #expect(controller.viewport.zoom.scale == 2)
        #expect(recorder.zooms.map(\.scale) == [2])
    }

    @Test func unchangedZoomIsNotReported() {
        let (controller, recorder) = makeController(mode: .direct)

        controller.pinch(by: 1, around: .zero)
        controller.resetZoom()

        #expect(recorder.zooms.isEmpty)
    }

    @Test func directTapsLandOnTheMagnifiedPictureUnderTheFinger() {
        let (controller, recorder) = makeController(mode: .direct)
        controller.pinch(by: 2, around: CGPoint(x: 200, y: 100))  // centre stays put, picture is 800 x 400

        controller.tap(at: CGPoint(x: 100, y: 100))

        // The view's left quarter now shows picture x from 0.25 to 0.375 of the way across: x = 100 is 0.375.
        #expect(recorder.events.first == .pointerMove(NormalizedPoint(x: 0.375, y: 0.5)))
    }

    @Test func resetReturnsToTheWholePicture() {
        let (controller, recorder) = makeController(mode: .direct)
        controller.pinch(by: 3, around: CGPoint(x: 50, y: 50))

        controller.resetZoom()

        #expect(controller.viewport.zoom == .identity)
        #expect(recorder.zooms.last == .identity)
    }

    @Test func panningMovesTheZoomedPictureWithinItsBounds() {
        let (controller, _) = makeController(mode: .direct)
        controller.pinch(by: 2, around: CGPoint(x: 200, y: 100))

        controller.panZoomedView(by: CGSize(width: 10_000, height: 0))

        #expect(controller.viewport.zoom.offset.width == 200)  // (800 - 400) / 2
    }

    @Test func trackpadModeScrollsTheViewToFollowThePointerOffscreen() {
        let (controller, recorder) = makeController(mode: .trackpad)
        controller.pinch(by: 4, around: CGPoint(x: 200, y: 100))
        recorder.zooms.removeAll()

        // Drag right a long way: the pointer would leave the visible part of the 4x picture.
        for _ in 0..<10 { controller.move(by: CGSize(width: 20, height: 0), to: .zero) }

        let rect = controller.viewport.videoRect
        let pointerX = rect.minX + rect.width * CGFloat(controller.cursor.position.x)
        #expect(pointerX <= 400 - ViewZoom.followMargin + 0.001)
        #expect(!recorder.zooms.isEmpty)
    }

    @Test func trackpadModeDoesNotMoveTheViewWhenNotZoomed() {
        let (controller, recorder) = makeController(mode: .trackpad)

        controller.move(by: CGSize(width: 30, height: 10), to: .zero)

        #expect(recorder.zooms.isEmpty)
    }

    @Test func scrollingStillUsesTheWholeSwipeDistanceFractionOfTheZoomedPicture() {
        let (controller, recorder) = makeController(mode: .direct)
        controller.pinch(by: 2, around: CGPoint(x: 200, y: 100))

        controller.scroll(by: CGSize(width: 0, height: 40))

        // 40 points of a 400-point-tall picture is 0.1 of a screen.
        #expect(recorder.events == [.scroll(dx: 0, dy: 0.1 * PointerController.scrollPixelsPerScreen)])
    }
}
