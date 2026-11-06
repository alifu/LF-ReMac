#!/usr/bin/env swift
// Generates the app icons (run from the repo root: `swift Tools/make-icons.swift`).
//   iOS : iOSClient/Assets.xcassets/AppIcon.appiconset/icon-1024.png (full-bleed; iOS applies the mask)
//   Mac : MacHost/Assets.xcassets/AppIcon.appiconset/icon_<size>.png (rounded square with margin)
import AppKit

let blue = NSColor(srgbRed: 0.10, green: 0.45, blue: 0.98, alpha: 1)
let indigo = NSColor(srgbRed: 0.30, green: 0.17, blue: 0.80, alpha: 1)

/// Draws the artwork into a square `size` canvas. `inset` shrinks the rounded plate (Mac icons need a margin).
func draw(size: CGFloat, rounded: Bool) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    let margin = rounded ? size * 0.098 : 0
    let plate = CGRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
    let radius = rounded ? plate.width * 0.2237 : 0

    ctx.saveGState()
    if rounded {
        ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.01), blur: size * 0.02, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.addPath(CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(blue.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
    }
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [blue.cgColor, indigo.cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: plate.minX, y: plate.maxY), end: CGPoint(x: plate.maxX, y: plate.minY), options: [])

    // Monitor: white rounded screen with a stand, centered a little above the middle.
    let unit = plate.width / 100
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: plate.minX + x * unit, y: plate.minY + y * unit) }
    let screen = CGRect(origin: p(16, 38), size: CGSize(width: 68 * unit, height: 44 * unit))
    ctx.setShadow(offset: CGSize(width: 0, height: -unit * 1.5), blur: unit * 4, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.addPath(CGPath(roundedRect: screen, cornerWidth: 5 * unit, cornerHeight: 5 * unit, transform: nil))
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    // Screen face (deep blue) inset from the bezel.
    let face = screen.insetBy(dx: 3.2 * unit, dy: 3.2 * unit)
    ctx.setFillColor(NSColor(srgbRed: 0.09, green: 0.12, blue: 0.30, alpha: 1).cgColor)
    ctx.addPath(CGPath(roundedRect: face, cornerWidth: 2.4 * unit, cornerHeight: 2.4 * unit, transform: nil))
    ctx.fillPath()
    // Stand.
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fill(CGRect(origin: p(44, 29), size: CGSize(width: 12 * unit, height: 9.5 * unit)))
    ctx.addPath(CGPath(roundedRect: CGRect(origin: p(33, 25), size: CGSize(width: 34 * unit, height: 5 * unit)),
                       cornerWidth: 2.5 * unit, cornerHeight: 2.5 * unit, transform: nil))
    ctx.fillPath()

    // Phone overlapping the monitor's lower-right corner, with a pointer cursor on the screen.
    let phone = CGRect(origin: p(62, 16), size: CGSize(width: 22 * unit, height: 38 * unit))
    ctx.setShadow(offset: CGSize(width: 0, height: -unit * 1.5), blur: unit * 4, color: NSColor.black.withAlphaComponent(0.4).cgColor)
    ctx.setFillColor(NSColor(srgbRed: 0.07, green: 0.08, blue: 0.16, alpha: 1).cgColor)
    ctx.addPath(CGPath(roundedRect: phone, cornerWidth: 4.2 * unit, cornerHeight: 4.2 * unit, transform: nil))
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(1.4 * unit)
    ctx.addPath(CGPath(roundedRect: phone, cornerWidth: 4.2 * unit, cornerHeight: 4.2 * unit, transform: nil))
    ctx.strokePath()
    let phoneFace = phone.insetBy(dx: 2 * unit, dy: 3.4 * unit)
    ctx.setFillColor(NSColor(srgbRed: 0.35, green: 0.62, blue: 1.0, alpha: 1).cgColor)
    ctx.addPath(CGPath(roundedRect: phoneFace, cornerWidth: 1.6 * unit, cornerHeight: 1.6 * unit, transform: nil))
    ctx.fillPath()

    // Cursor arrow on the monitor.
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.setStrokeColor(NSColor(srgbRed: 0.09, green: 0.12, blue: 0.30, alpha: 1).cgColor)
    ctx.setLineWidth(0.9 * unit)
    ctx.setLineJoin(.round)
    ctx.beginPath()
    ctx.move(to: p(30, 71))
    ctx.addLine(to: p(30, 51))
    ctx.addLine(to: p(34.6, 55.2))
    ctx.addLine(to: p(38.2, 48.4))
    ctx.addLine(to: p(41, 49.8))
    ctx.addLine(to: p(37.4, 56.6))
    ctx.addLine(to: p(43.4, 57))
    ctx.closePath()
    ctx.drawPath(using: .fillStroke)

    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, to path: String) throws {
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

try write(draw(size: 1024, rounded: false), to: "iOSClient/Assets.xcassets/AppIcon.appiconset/icon-1024.png")
for (point, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = point * scale
    try write(draw(size: CGFloat(pixels), rounded: true), to: "MacHost/Assets.xcassets/AppIcon.appiconset/icon_\(point)x\(point)@\(scale)x.png")
}
// Full-size preview used by the README.
try write(draw(size: 1024, rounded: true), to: "docs/images/app-icon.png")
print("icons written")
