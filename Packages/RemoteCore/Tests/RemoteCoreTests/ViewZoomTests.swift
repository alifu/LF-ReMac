import CoreGraphics
import Testing
@testable import RemoteCore

struct ViewZoomTests {
    private let viewSize = CGSize(width: 400, height: 800)
    private let videoSize = CGSize(width: 1600, height: 900)  // fits as 400 x 225, letterboxed
    private var base: VideoViewport { VideoViewport(viewSize: viewSize, videoSize: videoSize) }

    @Test func identityLeavesTheMappingUnchanged() {
        #expect(base.zoom == .identity)
        #expect(base.videoRect == CGRect(x: 0, y: 287.5, width: 400, height: 225))
    }

    @Test func zoomScalesThePictureAboutTheViewCentre() {
        let viewport = base.withZoom(ViewZoom(scale: 2, offset: .zero))

        #expect(viewport.videoRect == CGRect(x: -200, y: 175, width: 800, height: 450))
        #expect(viewport.normalizedPoint(for: CGPoint(x: 200, y: 400)) == NormalizedPoint(x: 0.5, y: 0.5))
    }

    @Test func scaleIsLimited() {
        #expect(ViewZoom(scale: 0.2, offset: .zero).scale == ViewZoom.minScale)
        #expect(ViewZoom(scale: 99, offset: .zero).scale == ViewZoom.maxScale)
        #expect(ViewZoom(scale: .nan, offset: .zero).scale == ViewZoom.minScale)
    }

    @Test func zoomingKeepsThePointUnderTheFingerInPlace() {
        // A 400 x 300 view: at 3x the picture (1200 x 675) overflows on both axes, so nothing is re-centred.
        let wide = VideoViewport(viewSize: CGSize(width: 400, height: 300), videoSize: videoSize)
        let anchor = CGPoint(x: 100, y: 150)
        let before = wide.normalizedPoint(for: anchor)

        let zoomed = ViewZoom.identity.zoomed(by: 3, around: anchor, in: wide)

        #expect(zoomed.scale == 3)
        let after = wide.withZoom(zoomed).normalizedPoint(for: anchor)
        #expect(abs(after.x - before.x) < 0.0001)
        #expect(abs(after.y - before.y) < 0.0001)
    }

    @Test func zoomingOutToOneRecentresThePicture() {
        let zoomed = ViewZoom.identity.zoomed(by: 4, around: CGPoint(x: 50, y: 300), in: base)

        let back = zoomed.zoomed(by: 0.1, around: CGPoint(x: 50, y: 300), in: base)

        #expect(back == .identity)
    }

    @Test func zoomingBeyondTheMaximumStopsThere() {
        let zoomed = ViewZoom.identity.zoomed(by: 100, around: CGPoint(x: 200, y: 400), in: base)

        #expect(zoomed.scale == ViewZoom.maxScale)
    }

    @Test func ignoresNonsenseFactors() {
        #expect(ViewZoom.identity.zoomed(by: 0, around: .zero, in: base) == .identity)
        #expect(ViewZoom.identity.zoomed(by: -2, around: .zero, in: base) == .identity)
        #expect(ViewZoom.identity.zoomed(by: .infinity, around: .zero, in: base) == .identity)
    }

    @Test func panningIsClampedSoThePictureAlwaysCoversTheView() {
        // Picture at 4x is 1600 x 900 in a 400 x 800 view: x may move +-600, y +-50.
        let zoom = ViewZoom(scale: 4, offset: .zero)

        let panned = zoom.panned(by: CGSize(width: 5000, height: -5000), in: base)

        #expect(panned.offset == CGSize(width: 600, height: -50))
    }

    @Test func thereIsNothingToPanWhilePictureFitsAlongAnAxis() {
        // At 2x the picture is 800 x 450: wider than the 400 view, shorter than the 800 view.
        let panned = ViewZoom(scale: 2, offset: .zero).panned(by: CGSize(width: 50, height: 300), in: base)

        #expect(panned.offset == CGSize(width: 50, height: 0))
    }

    @Test func zoomedTouchesMapToTheMagnifiedPicture() {
        let viewport = base.withZoom(ViewZoom(scale: 2, offset: .zero))

        // Picture spans x -200...600, y 175...625 on screen.
        #expect(viewport.normalizedPoint(for: CGPoint(x: 0, y: 175)) == NormalizedPoint(x: 0.25, y: 0))
        #expect(viewport.normalizedPoint(for: CGPoint(x: 400, y: 625)) == NormalizedPoint(x: 0.75, y: 1))
    }

    @Test func fingerMovesMoveThePointerLessWhileZoomedIn() {
        let delta = CGSize(width: 40, height: 0)

        let whole = base.normalizedDelta(for: delta)
        let magnified = base.withZoom(ViewZoom(scale: 2, offset: .zero)).normalizedDelta(for: delta)

        #expect(magnified.dx == whole.dx / 2)
    }

    @Test func followingBringsAnOffscreenPointerBackIntoView() {
        let zoom = ViewZoom(scale: 4, offset: .zero)  // the 400-wide view sees the middle quarter horizontally
        let pointer = NormalizedPoint(x: 0.95, y: 0.5)
        #expect(base.withZoom(zoom).videoRect.minX + base.withZoom(zoom).videoRect.width * 0.95 > 400)

        let followed = zoom.keepingVisible(pointer, in: base)

        let rect = base.withZoom(followed).videoRect
        let x = rect.minX + rect.width * 0.95
        #expect(x <= 400 - ViewZoom.followMargin + 0.001)
        #expect(x >= ViewZoom.followMargin)
    }

    @Test func followingDoesNothingWhenThePointerIsAlreadyVisibleOrNotZoomed() {
        let zoom = ViewZoom(scale: 3, offset: .zero)

        #expect(zoom.keepingVisible(.center, in: base) == zoom)
        #expect(ViewZoom.identity.keepingVisible(NormalizedPoint(x: 1, y: 1), in: base) == .identity)
    }
}
