import CoreGraphics
import Foundation

/// Pixel dimensions for the captured stream. Always even, as H.264 chroma subsampling requires.
struct CaptureSize: Equatable, Sendable {
    let width: Int
    let height: Int

    private static let minimumSide = 2

    /// Scales `width` x `height` down (never up) so the longer side is at most `maxLongSide`.
    static func fitting(width: Int, height: Int, maxLongSide: Int) -> CaptureSize {
        let longSide = max(width, height)
        let scale = longSide > maxLongSide ? Double(maxLongSide) / Double(longSide) : 1.0
        return CaptureSize(
            width: evenSide(Double(width) * scale),
            height: evenSide(Double(height) * scale)
        )
    }

    /// Main display in real pixels (not points), scaled to the limit. `ScreenCapturer` and the
    /// encoder must both use this so frame and encoder dimensions always match.
    static func mainDisplay(maxLongSide: Int) -> CaptureSize {
        let displayID = CGMainDisplayID()
        return fitting(
            width: CGDisplayPixelsWide(displayID),
            height: CGDisplayPixelsHigh(displayID),
            maxLongSide: maxLongSide
        )
    }

    private static func evenSide(_ value: Double) -> Int {
        let even = Int(value.rounded(.down)) & ~1
        return max(even, minimumSide)
    }
}
