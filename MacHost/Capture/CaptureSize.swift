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

    private static func evenSide(_ value: Double) -> Int {
        let even = Int(value.rounded(.down)) & ~1
        return max(even, minimumSide)
    }
}
