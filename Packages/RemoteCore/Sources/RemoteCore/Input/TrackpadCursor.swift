import CoreGraphics
import Foundation

/// The remote pointer position in trackpad mode: finger movements move it relatively, like a laptop trackpad.
/// Immutable; every change returns a new value.
public struct TrackpadCursor: Equatable, Sendable {
    /// Finger travel of half the video width crosses the whole screen.
    public static let defaultGain = 2.0

    public let position: NormalizedPoint
    public let gain: Double

    public init(position: NormalizedPoint = .center, gain: Double = TrackpadCursor.defaultGain) {
        self.position = position
        self.gain = gain
    }

    public func moved(by viewDelta: CGSize, in viewport: VideoViewport) -> TrackpadCursor {
        let delta = viewport.normalizedDelta(for: viewDelta)
        let next = NormalizedPoint(x: position.x + delta.dx * gain, y: position.y + delta.dy * gain)
        return TrackpadCursor(position: next, gain: gain)
    }

    public func placed(at point: NormalizedPoint) -> TrackpadCursor {
        TrackpadCursor(position: point, gain: gain)
    }
}
