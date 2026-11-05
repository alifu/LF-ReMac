import AVFoundation
import SwiftUI
import UIKit

/// Hosts the renderer's `AVSampleBufferDisplayLayer` in SwiftUI.
struct VideoView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> LayerHostView {
        LayerHostView(hostedLayer: layer)
    }

    func updateUIView(_ uiView: LayerHostView, context: Context) {}
}

final class LayerHostView: UIView {
    private let hostedLayer: CALayer

    init(hostedLayer: CALayer) {
        self.hostedLayer = hostedLayer
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(hostedLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostedLayer.frame = bounds
        CATransaction.commit()
    }
}
