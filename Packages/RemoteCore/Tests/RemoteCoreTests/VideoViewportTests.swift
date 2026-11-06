import CoreGraphics
import Testing
@testable import RemoteCore

struct VideoViewportTests {
    @Test func videoFillsViewWhenAspectRatiosMatch() {
        let viewport = VideoViewport(viewSize: CGSize(width: 400, height: 225), videoSize: CGSize(width: 1920, height: 1080))

        #expect(viewport.videoRect == CGRect(x: 0, y: 0, width: 400, height: 225))
    }

    @Test func letterboxesWideVideoInTallView() {
        let viewport = VideoViewport(viewSize: CGSize(width: 400, height: 800), videoSize: CGSize(width: 1600, height: 900))

        #expect(viewport.videoRect == CGRect(x: 0, y: 287.5, width: 400, height: 225))
    }

    @Test func pillarboxesTallVideoInWideView() {
        let viewport = VideoViewport(viewSize: CGSize(width: 800, height: 400), videoSize: CGSize(width: 900, height: 1600))

        #expect(viewport.videoRect == CGRect(x: 287.5, y: 0, width: 225, height: 400))
    }

    @Test func mapsCornersAndCenterOfVideoRect() {
        let viewport = VideoViewport(viewSize: CGSize(width: 400, height: 800), videoSize: CGSize(width: 1600, height: 900))

        #expect(viewport.normalizedPoint(for: CGPoint(x: 0, y: 287.5)) == NormalizedPoint(x: 0, y: 0))
        #expect(viewport.normalizedPoint(for: CGPoint(x: 400, y: 512.5)) == NormalizedPoint(x: 1, y: 1))
        #expect(viewport.normalizedPoint(for: CGPoint(x: 200, y: 400)) == NormalizedPoint(x: 0.5, y: 0.5))
    }

    @Test func clampsTouchesInsideTheBlackBars() {
        let viewport = VideoViewport(viewSize: CGSize(width: 400, height: 800), videoSize: CGSize(width: 1600, height: 900))

        #expect(viewport.normalizedPoint(for: CGPoint(x: 200, y: 0)) == NormalizedPoint(x: 0.5, y: 0))
        #expect(viewport.normalizedPoint(for: CGPoint(x: 200, y: 800)) == NormalizedPoint(x: 0.5, y: 1))
    }

    @Test func normalizesDeltasAgainstDisplayedVideoSize() {
        let viewport = VideoViewport(viewSize: CGSize(width: 400, height: 225), videoSize: CGSize(width: 1920, height: 1080))

        let delta = viewport.normalizedDelta(for: CGSize(width: 100, height: -45))

        #expect(delta.dx == 0.25)
        #expect(delta.dy == -0.2)
    }

    @Test func degenerateSizesMapToCenterWithoutCrashing() {
        let viewport = VideoViewport(viewSize: .zero, videoSize: .zero)

        #expect(viewport.videoRect == .zero)
        #expect(viewport.normalizedPoint(for: CGPoint(x: 10, y: 10)) == NormalizedPoint(x: 0.5, y: 0.5))
        #expect(viewport.normalizedDelta(for: CGSize(width: 5, height: 5)) == (0, 0))
    }
}
