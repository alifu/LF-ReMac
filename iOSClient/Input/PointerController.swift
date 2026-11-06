import CoreGraphics
import Foundation
import RemoteCore

/// Turns touch gestures into pointer events. Pure logic: the UIKit layer feeds it view-space data,
/// and it reports `InputEvent`s through `send`.
///
/// - Trackpad mode: finger movement moves the pointer relatively; taps click where the pointer is.
/// - Direct mode: the pointer goes where the finger touches.
@MainActor
final class PointerController {
    enum Mode: Equatable {
        case trackpad
        case direct
    }

    /// A finger sweep across the full video height scrolls about one screenful.
    static let scrollPixelsPerScreen = 1200.0

    var mode: Mode
    var viewport = VideoViewport(viewSize: .zero, videoSize: .zero)
    /// Called when a gesture (pinch, pan, following the pointer, reset) changes the zoom, so the
    /// video can be redrawn to match.
    var onZoomChange: (@MainActor (ViewZoom) -> Void)?
    private(set) var cursor = TrackpadCursor()
    private(set) var isDragging = false
    private let send: @MainActor (InputEvent) -> Void

    init(mode: Mode = .trackpad, send: @escaping @MainActor (InputEvent) -> Void) {
        self.mode = mode
        self.send = send
    }

    func tap(at location: CGPoint) {
        click(.left, at: pointerPosition(for: location))
    }

    func rightTap(at location: CGPoint) {
        click(.right, at: pointerPosition(for: location))
    }

    /// One-finger movement. `delta` is since the previous callback, `location` the finger's current position.
    func move(by delta: CGSize, to location: CGPoint) {
        switch mode {
        case .trackpad:
            cursor = cursor.moved(by: delta, in: viewport)
            followPointerIfZoomed()
        case .direct:
            cursor = cursor.placed(at: viewport.normalizedPoint(for: location))
        }
        send(.pointerMove(cursor.position))
    }

    func beginDrag(at location: CGPoint) {
        let position = pointerPosition(for: location)
        send(.pointerMove(position))
        send(.button(.left, isDown: true, at: position))
        isDragging = true
    }

    func endDrag() {
        guard isDragging else { return }
        isDragging = false
        send(.button(.left, isDown: false, at: cursor.position))
    }

    /// Two-finger movement. `delta` is the finger movement in view points since the previous callback.
    func scroll(by delta: CGSize) {
        let fraction = viewport.normalizedDelta(for: delta)
        guard fraction.dx != 0 || fraction.dy != 0 else { return }
        send(.scroll(dx: fraction.dx * Self.scrollPixelsPerScreen, dy: fraction.dy * Self.scrollPixelsPerScreen))
    }

    // MARK: - Zoom

    /// Pinch: zoom by `factor` keeping the picture under `anchor` (a view position) in place.
    func pinch(by factor: CGFloat, around anchor: CGPoint) {
        setZoom(viewport.zoom.zoomed(by: factor, around: anchor, in: viewport))
    }

    /// Moves the zoomed picture with the fingers (`delta` in view points).
    func panZoomedView(by delta: CGSize) {
        setZoom(viewport.zoom.panned(by: delta, in: viewport))
    }

    func resetZoom() {
        setZoom(.identity)
    }

    private func followPointerIfZoomed() {
        setZoom(viewport.zoom.keepingVisible(cursor.position, in: viewport))
    }

    private func setZoom(_ zoom: ViewZoom) {
        guard zoom != viewport.zoom else { return }
        viewport = viewport.withZoom(zoom)
        onZoomChange?(zoom)
    }

    // MARK: - Helpers

    /// Where a tap or drag start lands; in direct mode this also moves the tracked cursor there.
    private func pointerPosition(for location: CGPoint) -> NormalizedPoint {
        if mode == .direct {
            cursor = cursor.placed(at: viewport.normalizedPoint(for: location))
        }
        return cursor.position
    }

    private func click(_ button: PointerButton, at position: NormalizedPoint) {
        send(.pointerMove(position))
        send(.button(button, isDown: true, at: position))
        send(.button(button, isDown: false, at: position))
    }
}
