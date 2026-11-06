import AVFoundation
import RemoteCore
import SwiftUI
import UIKit

/// Hosts the renderer's `AVSampleBufferDisplayLayer` in SwiftUI.
struct VideoView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    let zoom: ViewZoom

    func makeUIView(context: Context) -> LayerHostView {
        LayerHostView(hostedLayer: layer)
    }

    func updateUIView(_ uiView: LayerHostView, context: Context) {
        uiView.zoom = zoom
    }
}

final class LayerHostView: UIView {
    private let hostedLayer: CALayer

    /// Magnifies the picture about the view centre, then shifts it (see `ViewZoom`).
    var zoom: ViewZoom = .identity {
        didSet { if zoom != oldValue { applyLayout() } }
    }

    init(hostedLayer: CALayer) {
        self.hostedLayer = hostedLayer
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true
        layer.addSublayer(hostedLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyLayout()
    }

    private func applyLayout() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // `frame` is meaningless under a transform, so reset it, size the layer, then zoom.
        hostedLayer.setAffineTransform(.identity)
        hostedLayer.frame = bounds
        hostedLayer.setAffineTransform(
            CGAffineTransform(translationX: zoom.offset.width, y: zoom.offset.height).scaledBy(x: zoom.scale, y: zoom.scale)
        )
        CATransaction.commit()
    }
}
