import CoreGraphics
import Foundation
import RemoteCore
import Testing
@testable import iOSClient

@MainActor
struct PointerControllerTests {
    private final class Recorder {
        var events: [InputEvent] = []
    }

    private func makeController(mode: PointerController.Mode) -> (PointerController, Recorder) {
        let recorder = Recorder()
        let controller = PointerController(mode: mode) { recorder.events.append($0) }
        controller.viewport = VideoViewport(viewSize: CGSize(width: 400, height: 200), videoSize: CGSize(width: 1600, height: 800))
        return (controller, recorder)
    }

    @Test func trackpadTapClicksAtTheCursorNotTheTouch() {
        let (controller, recorder) = makeController(mode: .trackpad)

        controller.tap(at: CGPoint(x: 10, y: 10))

        #expect(recorder.events == [
            .pointerMove(.center),
            .button(.left, isDown: true, at: .center),
            .button(.left, isDown: false, at: .center)
        ])
    }

    @Test func directTapClicksWhereTheFingerTouches() {
        let (controller, recorder) = makeController(mode: .direct)
        let target = NormalizedPoint(x: 0.25, y: 0.5)

        controller.tap(at: CGPoint(x: 100, y: 100))

        #expect(recorder.events == [
            .pointerMove(target),
            .button(.left, isDown: true, at: target),
            .button(.left, isDown: false, at: target)
        ])
    }

    @Test func rightTapSendsRightButton() {
        let (controller, recorder) = makeController(mode: .trackpad)

        controller.rightTap(at: .zero)

        #expect(recorder.events.contains(.button(.right, isDown: true, at: .center)))
        #expect(recorder.events.contains(.button(.right, isDown: false, at: .center)))
    }

    @Test func trackpadPanMovesPointerRelatively() throws {
        let (controller, recorder) = makeController(mode: .trackpad)

        controller.move(by: CGSize(width: 40, height: 0), to: CGPoint(x: 999, y: 999))

        guard case .pointerMove(let point) = try #require(recorder.events.first) else {
            Issue.record("expected a pointer move")
            return
        }
        #expect(abs(point.x - 0.7) < 1e-9)
        #expect(point.y == 0.5)
    }

    @Test func directPanFollowsTheFinger() {
        let (controller, recorder) = makeController(mode: .direct)

        controller.move(by: CGSize(width: 5, height: 5), to: CGPoint(x: 200, y: 50))

        #expect(recorder.events == [.pointerMove(NormalizedPoint(x: 0.5, y: 0.25))])
    }

    @Test func dragPressesMovesAndReleasesAtCursor() {
        let (controller, recorder) = makeController(mode: .trackpad)

        controller.beginDrag(at: .zero)
        controller.move(by: CGSize(width: 20, height: 0), to: .zero)
        controller.endDrag()

        #expect(recorder.events.count == 4)
        #expect(recorder.events[0] == .pointerMove(.center))
        #expect(recorder.events[1] == .button(.left, isDown: true, at: .center))
        #expect(controller.isDragging == false)
        guard case .button(.left, false, _) = recorder.events[3] else {
            Issue.record("expected a left button release")
            return
        }
    }

    @Test func isDraggingBetweenBeginAndEnd() {
        let (controller, _) = makeController(mode: .trackpad)

        controller.beginDrag(at: .zero)

        #expect(controller.isDragging)
    }

    @Test func scrollIsProportionalToFractionOfVideoCrossed() throws {
        let (controller, recorder) = makeController(mode: .trackpad)

        controller.scroll(by: CGSize(width: 0, height: 100))  // half the 200pt tall video

        let event = try #require(recorder.events.first)
        guard case .scroll(let dx, let dy) = event else {
            Issue.record("expected a scroll event")
            return
        }
        #expect(dx == 0)
        #expect(dy == PointerController.scrollPixelsPerScreen * 0.5)
    }

    @Test func zeroScrollSendsNothing() {
        let (controller, recorder) = makeController(mode: .trackpad)

        controller.scroll(by: .zero)

        #expect(recorder.events.isEmpty)
    }

    @Test func switchingModeKeepsTheCursorPosition() {
        let (controller, _) = makeController(mode: .direct)
        controller.move(by: .zero, to: CGPoint(x: 100, y: 100))

        controller.mode = .trackpad

        #expect(controller.cursor.position == NormalizedPoint(x: 0.25, y: 0.5))
    }
}
