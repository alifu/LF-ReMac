import RemoteCore
import SwiftUI
import UIKit

/// Transparent layer above the video that turns touches into pointer events.
///
/// One finger: tap = left click, drag = move. Hold then drag = click-and-drag.
/// Two fingers: tap = right click, drag = scroll, pinch = zoom (and moving the fingers while
/// pinching moves the zoomed picture).
struct InputSurface: UIViewRepresentable {
    let controller: PointerController
    let videoSize: CGSize
    let zoom: ViewZoom

    func makeUIView(context: Context) -> GestureView {
        GestureView(controller: controller)
    }

    func updateUIView(_ uiView: GestureView, context: Context) {
        uiView.videoSize = videoSize
        uiView.zoom = zoom
    }
}

final class GestureView: UIView, UIGestureRecognizerDelegate {
    private static let longPressDuration: TimeInterval = 0.35
    private static let longPressSlop: CGFloat = 12
    /// A two-finger drag only counts as a pinch once the fingers have spread or closed by this much,
    /// so ordinary scrolling is not mistaken for zooming.
    private static let pinchActivationDistance: CGFloat = 0.06

    var videoSize: CGSize = .zero {
        didSet { if videoSize != oldValue { updateViewport() } }
    }
    var zoom: ViewZoom = .identity {
        didSet { if zoom != oldValue { updateViewport() } }
    }

    private let controller: PointerController
    private var lastPanTranslation: CGPoint = .zero
    private var lastScrollTranslation: CGPoint = .zero
    private var lastPinchScale: CGFloat = 1
    private var lastPinchCentre: CGPoint = .zero
    private var isPinching = false

    init(controller: PointerController) {
        self.controller = controller
        super.init(frame: .zero)
        backgroundColor = .clear
        installRecognizers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateViewport()
    }

    private func updateViewport() {
        let base = VideoViewport(viewSize: bounds.size, videoSize: videoSize)
        controller.viewport = base.withZoom(zoom.clamped(in: base))
    }

    // MARK: - Recognizers

    private func installRecognizers() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap))
        twoFingerTap.numberOfTouchesRequired = 2
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
        longPress.minimumPressDuration = Self.longPressDuration
        longPress.allowableMovement = Self.longPressSlop

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))

        for recognizer in [tap, twoFingerTap, pan, scroll, longPress, pinch] {
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        // Hold-then-drag needs the long press and the one-finger pan to run together.
        (gestureRecognizer is UILongPressGestureRecognizer && other is UIPanGestureRecognizer)
            || (gestureRecognizer is UIPanGestureRecognizer && other is UILongPressGestureRecognizer)
            // Pinching and the two-finger scroll see the same touches; the handlers sort out which wins.
            || (gestureRecognizer is UIPinchGestureRecognizer && other is UIPanGestureRecognizer)
            || (gestureRecognizer is UIPanGestureRecognizer && other is UIPinchGestureRecognizer)
    }

    // MARK: - Handlers

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        controller.tap(at: recognizer.location(in: self))
    }

    @objc private func handleTwoFingerTap(_ recognizer: UITapGestureRecognizer) {
        controller.rightTap(at: recognizer.location(in: self))
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: self)
        if recognizer.state == .began { lastPanTranslation = .zero }
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        let delta = CGSize(width: translation.x - lastPanTranslation.x, height: translation.y - lastPanTranslation.y)
        lastPanTranslation = translation
        controller.move(by: delta, to: recognizer.location(in: self))
    }

    @objc private func handleScroll(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: self)
        if recognizer.state == .began { lastScrollTranslation = .zero }
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        let delta = CGSize(width: translation.x - lastScrollTranslation.x, height: translation.y - lastScrollTranslation.y)
        lastScrollTranslation = translation
        guard !isPinching else { return }
        controller.scroll(by: delta)
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        let centre = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            lastPinchScale = 1
            lastPinchCentre = centre
            isPinching = false
        case .changed:
            if !isPinching {
                guard abs(recognizer.scale - 1) > Self.pinchActivationDistance else { return }
                isPinching = true
                lastPinchScale = recognizer.scale
                lastPinchCentre = centre
                return
            }
            controller.pinch(by: recognizer.scale / lastPinchScale, around: centre)
            controller.panZoomedView(by: CGSize(width: centre.x - lastPinchCentre.x, height: centre.y - lastPinchCentre.y))
            lastPinchScale = recognizer.scale
            lastPinchCentre = centre
        default:
            isPinching = false
        }
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            controller.beginDrag(at: recognizer.location(in: self))
        case .ended, .cancelled, .failed:
            controller.endDrag()
        default:
            break
        }
    }
}
