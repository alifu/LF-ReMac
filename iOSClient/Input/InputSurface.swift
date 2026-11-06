import RemoteCore
import SwiftUI
import UIKit

/// Transparent layer above the video that turns touches into pointer events.
///
/// One finger: tap = left click, drag = move. Hold then drag = click-and-drag.
/// Two fingers: tap = right click, drag = scroll.
struct InputSurface: UIViewRepresentable {
    let controller: PointerController
    let videoSize: CGSize

    func makeUIView(context: Context) -> GestureView {
        GestureView(controller: controller)
    }

    func updateUIView(_ uiView: GestureView, context: Context) {
        uiView.videoSize = videoSize
    }
}

final class GestureView: UIView, UIGestureRecognizerDelegate {
    private static let longPressDuration: TimeInterval = 0.35
    private static let longPressSlop: CGFloat = 12

    var videoSize: CGSize = .zero {
        didSet { if videoSize != oldValue { updateViewport() } }
    }

    private let controller: PointerController
    private var lastPanTranslation: CGPoint = .zero
    private var lastScrollTranslation: CGPoint = .zero

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
        controller.viewport = VideoViewport(viewSize: bounds.size, videoSize: videoSize)
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

        for recognizer in [tap, twoFingerTap, pan, scroll, longPress] {
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
        controller.scroll(by: delta)
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
