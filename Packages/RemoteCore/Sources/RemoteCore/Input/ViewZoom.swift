import CoreGraphics
import Foundation

/// How far the viewer has zoomed into the remote picture and where it sits, as an immutable value.
///
/// `scale` multiplies the aspect-fit picture size (1 = whole picture visible, letterboxed).
/// `offset` is how far the picture's centre sits from the view's centre, in view points. Every
/// operation returns a new, clamped value, so the picture can never be dragged off the view
/// (there is nothing to drag while it still fits).
public struct ViewZoom: Equatable, Sendable {
    public static let minScale: CGFloat = 1
    public static let maxScale: CGFloat = 5
    /// Keeps the pointer this far from the view edge when following it while zoomed in.
    public static let followMargin: CGFloat = 40
    public static let identity = ViewZoom(scale: 1, offset: .zero)

    public let scale: CGFloat
    public let offset: CGSize

    /// `scale` is limited to `minScale...maxScale`; NaN becomes `minScale`.
    public init(scale: CGFloat, offset: CGSize) {
        let finite = scale.isNaN ? Self.minScale : scale
        self.scale = min(max(finite, Self.minScale), Self.maxScale)
        self.offset = offset
    }

    public var isZoomed: Bool { scale > Self.minScale + 0.001 }

    /// Zooms by `factor` keeping the picture point under `anchor` (a view position) where it is.
    public func zoomed(by factor: CGFloat, around anchor: CGPoint, in viewport: VideoViewport) -> ViewZoom {
        guard factor.isFinite, factor > 0 else { return self }
        let next = ViewZoom(scale: scale * factor, offset: offset)
        let ratio = next.scale / scale
        let size = viewport.viewSize
        let centre = CGPoint(x: size.width / 2 + offset.width, y: size.height / 2 + offset.height)
        let newCentre = CGPoint(x: anchor.x + (centre.x - anchor.x) * ratio, y: anchor.y + (centre.y - anchor.y) * ratio)
        let moved = CGSize(width: newCentre.x - size.width / 2, height: newCentre.y - size.height / 2)
        return ViewZoom(scale: next.scale, offset: moved).clamped(in: viewport)
    }

    public func panned(by delta: CGSize, in viewport: VideoViewport) -> ViewZoom {
        ViewZoom(scale: scale, offset: CGSize(width: offset.width + delta.width, height: offset.height + delta.height))
            .clamped(in: viewport)
    }

    /// Pulls the offset back so the picture always covers the view along any axis where it is larger.
    public func clamped(in viewport: VideoViewport) -> ViewZoom {
        let fit = VideoViewport.fitSize(viewSize: viewport.viewSize, videoSize: viewport.videoSize)
        let limitX = max(0, (fit.width * scale - viewport.viewSize.width) / 2)
        let limitY = max(0, (fit.height * scale - viewport.viewSize.height) / 2)
        return ViewZoom(
            scale: scale,
            offset: CGSize(
                width: min(max(offset.width, -limitX), limitX),
                height: min(max(offset.height, -limitY), limitY)
            )
        )
    }

    /// Moves the picture just enough that the remote pointer at `point` is inside the view.
    public func keepingVisible(_ point: NormalizedPoint, in viewport: VideoViewport) -> ViewZoom {
        guard isZoomed else { return self }
        let shown = VideoViewport(viewSize: viewport.viewSize, videoSize: viewport.videoSize, zoom: self).videoRect
        let x = shown.minX + shown.width * CGFloat(point.x)
        let y = shown.minY + shown.height * CGFloat(point.y)
        let margin = Self.followMargin
        let dx = Self.shift(for: x, lower: margin, upper: viewport.viewSize.width - margin)
        let dy = Self.shift(for: y, lower: margin, upper: viewport.viewSize.height - margin)
        return panned(by: CGSize(width: dx, height: dy), in: viewport)
    }

    private static func shift(for value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        if value < lower { return lower - value }
        if value > upper { return upper - value }
        return 0
    }
}
