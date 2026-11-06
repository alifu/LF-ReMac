import CoreGraphics
import Testing
@testable import RemoteCore

struct TrackpadCursorTests {
    private let viewport = VideoViewport(viewSize: CGSize(width: 400, height: 200), videoSize: CGSize(width: 1600, height: 800))

    @Test func startsInTheCenter() {
        #expect(TrackpadCursor().position == NormalizedPoint(x: 0.5, y: 0.5))
    }

    @Test func movesProportionallyToFingerDeltaTimesGain() {
        let cursor = TrackpadCursor(gain: 2)

        let moved = cursor.moved(by: CGSize(width: 40, height: 10), in: viewport)

        #expect(abs(moved.position.x - 0.7) < 1e-9)
        #expect(abs(moved.position.y - 0.6) < 1e-9)
    }

    @Test func staysInsideTheScreenEdges() {
        let cursor = TrackpadCursor(position: NormalizedPoint(x: 0.9, y: 0.1), gain: 2)

        let moved = cursor.moved(by: CGSize(width: 400, height: -400), in: viewport)

        #expect(moved.position == NormalizedPoint(x: 1, y: 0))
    }

    @Test func movingDoesNotMutateTheOriginal() {
        let cursor = TrackpadCursor()

        _ = cursor.moved(by: CGSize(width: 50, height: 50), in: viewport)

        #expect(cursor.position == NormalizedPoint(x: 0.5, y: 0.5))
    }

    @Test func ignoresMovesWhenViewportIsDegenerate() {
        let cursor = TrackpadCursor()

        let moved = cursor.moved(by: CGSize(width: 50, height: 50), in: VideoViewport(viewSize: .zero, videoSize: .zero))

        #expect(moved.position == cursor.position)
    }

    @Test func canBePlacedAtAnAbsolutePoint() {
        let placed = TrackpadCursor().placed(at: NormalizedPoint(x: 0.2, y: 0.8))

        #expect(placed.position == NormalizedPoint(x: 0.2, y: 0.8))
    }
}
