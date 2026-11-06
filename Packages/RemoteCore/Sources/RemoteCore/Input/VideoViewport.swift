import CoreGraphics
import Foundation

/// Maps touch positions in a view to positions on the remote screen when the video is shown
/// aspect-fit (letterboxed) inside the view.
public struct VideoViewport: Equatable, Sendable {
    public let viewSize: CGSize
    public let videoSize: CGSize

    public init(viewSize: CGSize, videoSize: CGSize) {
        self.viewSize = viewSize
        self.videoSize = videoSize
    }

    /// Where the video is drawn inside the view (centered, aspect-fit). `.zero` for degenerate sizes.
    public var videoRect: CGRect {
        guard viewSize.width > 0, viewSize.height > 0, videoSize.width > 0, videoSize.height > 0 else { return .zero }
        let scale = min(viewSize.width / videoSize.width, viewSize.height / videoSize.height)
        let width = videoSize.width * scale
        let height = videoSize.height * scale
        return CGRect(x: (viewSize.width - width) / 2, y: (viewSize.height - height) / 2, width: width, height: height)
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
