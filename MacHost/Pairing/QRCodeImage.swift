import AppKit
import CoreImage

/// Renders a QR code as a crisp, white-bordered bitmap for the pairing window.
enum QRCodeImage {
    /// Level Q recovers about 25% damage, which tolerates a glare or a smudged screen.
    static let correctionLevel = "Q"
    /// The QR specification asks for at least four modules of quiet zone.
    static let quietZoneModules = 4
    static let defaultPointsPerModule = 8

    /// Nil for an empty string, a non-positive scale, or a message the generator cannot encode.
    static func make(from string: String, pointsPerModule: Int = defaultPointsPerModule) -> NSImage? {
        guard !string.isEmpty, pointsPerModule > 0 else { return nil }
        guard let modules = moduleImage(for: string) else { return nil }
        guard let bitmap = renderBitmap(modules: modules, pointsPerModule: pointsPerModule) else { return nil }
        let side = CGFloat(bitmap.width)
        return NSImage(cgImage: bitmap, size: NSSize(width: side, height: side))
    }

    /// One pixel per module, rendered by Core Image without scaling.
    private static func moduleImage(for string: String) -> CGImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue(correctionLevel, forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage, output.extent.width > 0 else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }

    /// Draws the modules with nearest-neighbour scaling onto a white, quiet-zone-padded canvas.
    private static func renderBitmap(modules: CGImage, pointsPerModule: Int) -> CGImage? {
        let moduleCount = modules.width
        let totalModules = moduleCount + 2 * quietZoneModules
        let side = totalModules * pointsPerModule
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .none
        let inset = CGFloat(quietZoneModules * pointsPerModule)
        let drawSide = CGFloat(moduleCount * pointsPerModule)
        context.draw(modules, in: CGRect(x: inset, y: inset, width: drawSide, height: drawSide))
        return context.makeImage()
    }
}
