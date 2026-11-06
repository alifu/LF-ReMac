import CoreGraphics
import Foundation

/// Maps touch positions in a view to positions on the remote screen when the video is shown
/// aspect-fit (letterboxed) inside the view.
public struct VideoViewport: Equatable, Sendable {
    public let viewSize: CGSize
    public let videoSize: CGSize
    /// How far the viewer has zoomed in; `.identity` shows the whole picture.
    public let zoom: ViewZoom

    public init(viewSize: CGSize, videoSize: CGSize, zoom: ViewZoom = .identity) {
        self.viewSize = viewSize
        self.videoSize = videoSize
        self.zoom = zoom
    }

    public func withZoom(_ zoom: ViewZoom) -> VideoViewport {
        VideoViewport(viewSize: viewSize, videoSize: videoSize, zoom: zoom)
    }

    /// Size of the whole picture drawn aspect-fit inside `viewSize` (before any zoom).
    static func fitSize(viewSize: CGSize, videoSize: CGSize) -> CGSize {
        guard viewSize.width > 0, viewSize.height > 0, videoSize.width > 0, videoSize.height > 0 else { return .zero }
        let scale = min(viewSize.width / videoSize.width, viewSize.height / videoSize.height)
        return CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
    }

    /// Where the video is drawn inside the view (aspect-fit, then zoomed about the view centre and
    /// shifted by the zoom offset). `.zero` for degenerate sizes.
    public var videoRect: CGRect {
        let fit = Self.fitSize(viewSize: viewSize, videoSize: videoSize)
        guard fit != .zero else { return .zero }
        let width = fit.width * zoom.scale
        let height = fit.height * zoom.scale
        return CGRect(
            x: (viewSize.width - width) / 2 + zoom.offset.width,
            y: (viewSize.height - height) / 2 + zoom.offset.height,
            width: width,
            height: height
        )
    }

    /// Remote-screen position under `viewPoint`; points over the black bars snap to the nearest edge.
    public func normalizedPoint(for viewPoint: CGPoint) -> NormalizedPoint {
        let rect = videoRect
        guard rect.width > 0, rect.height > 0 else { return .center }
        return NormalizedPoint(
            x: Double((viewPoint.x - rect.minX) / rect.width),
            y: Double((viewPoint.y - rect.minY) / rect.height)
        )
    }

    /// A finger movement expressed as a fraction of the displayed video size.
    public func normalizedDelta(for viewDelta: CGSize) -> (dx: Double, dy: Double) {
        let rect = videoRect
        guard rect.width > 0, rect.height > 0 else { return (0, 0) }
        return (Double(viewDelta.width / rect.width), Double(viewDelta.height / rect.height))
    }
}
