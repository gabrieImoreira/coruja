#!/usr/bin/env swift
// Generates Packaging/AppIcon.iconset (all required sizes): the "Clássica"
// owl mark — black silhouette, white eye-mask, black pupils, on a white
// rounded-square background — matching the app's light-menu-bar glyph.
// Run once; `iconutil` turns the .iconset into .icns
// (`iconutil -c icns Packaging/AppIcon.iconset -o Packaging/AppIcon.icns`).
import AppKit

let sizes: [(Int, String)] = [
    (16, "16x16"), (32, "16x16@2x"),
    (32, "32x32"), (64, "32x32@2x"),
    (128, "128x128"), (256, "128x128@2x"),
    (256, "256x256"), (512, "256x256@2x"),
    (512, "512x512"), (1024, "512x512@2x"),
]

let outDir = "Packaging/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

/// The owl's outline in a 64x64 SVG-style coordinate space (origin top-left,
/// y grows downward) — same path as the "Clássica" candidate reviewed and
/// approved in the icon comparison artifact.
func owlOutline() -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: 32, y: 3))
    path.curve(to: NSPoint(x: 21, y: 13), controlPoint1: NSPoint(x: 26, y: 3), controlPoint2: NSPoint(x: 23, y: 9))
    path.curve(to: NSPoint(x: 6, y: 33), controlPoint1: NSPoint(x: 13, y: 15), controlPoint2: NSPoint(x: 6, y: 23))
    path.curve(to: NSPoint(x: 20, y: 60), controlPoint1: NSPoint(x: 6, y: 46), controlPoint2: NSPoint(x: 12, y: 56))
    path.line(to: NSPoint(x: 26, y: 52))
    path.line(to: NSPoint(x: 32, y: 60))
    path.line(to: NSPoint(x: 38, y: 52))
    path.line(to: NSPoint(x: 44, y: 60))
    path.curve(to: NSPoint(x: 58, y: 33), controlPoint1: NSPoint(x: 52, y: 56), controlPoint2: NSPoint(x: 58, y: 46))
    path.curve(to: NSPoint(x: 43, y: 13), controlPoint1: NSPoint(x: 58, y: 23), controlPoint2: NSPoint(x: 51, y: 15))
    path.curve(to: NSPoint(x: 32, y: 3), controlPoint1: NSPoint(x: 41, y: 9), controlPoint2: NSPoint(x: 38, y: 3))
    path.close()
    return path
}

func rotatedEllipse(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat, degrees: CGFloat) -> NSBezierPath {
    let oval = NSBezierPath(ovalIn: NSRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2))
    var transform = AffineTransform.identity
    transform.translate(x: cx, y: cy)
    transform.rotate(byDegrees: degrees)
    oval.transform(using: transform)
    return oval
}

func render(px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx

    let full = NSRect(x: 0, y: 0, width: px, height: px)
    let corner = CGFloat(px) * 0.22
    let bg = NSBezierPath(roundedRect: full, xRadius: corner, yRadius: corner)
    NSColor.white.setFill()
    bg.fill()
    NSColor(calibratedWhite: 0.85, alpha: 1.0).setStroke()
    bg.lineWidth = CGFloat(px) * 0.006
    bg.stroke()

    // Map the owl's 64x64 SVG-style space (origin top-left, y down) onto a
    // centered, padded square within the icon canvas.
    let contentSize = CGFloat(px) * 0.72
    let margin = (CGFloat(px) - contentSize) / 2
    let scale = contentSize / 64
    ctx.cgContext.saveGState()
    ctx.cgContext.translateBy(x: margin, y: CGFloat(px) - margin)
    ctx.cgContext.scaleBy(x: scale, y: -scale)

    let ink = NSColor(calibratedWhite: 0.11, alpha: 1.0)

    ink.setFill()
    owlOutline().fill()
    rotatedEllipse(cx: 19, cy: 9, rx: 4.2, ry: 7.5, degrees: -24).fill()
    rotatedEllipse(cx: 45, cy: 9, rx: 4.2, ry: 7.5, degrees: 24).fill()

    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: 25 - 10, y: 28 - 10, width: 20, height: 20)).fill()
    NSBezierPath(ovalIn: NSRect(x: 39 - 10, y: 28 - 10, width: 20, height: 20)).fill()

    ink.setFill()
    NSBezierPath(ovalIn: NSRect(x: 25 - 3.2, y: 28 - 3.2, width: 6.4, height: 6.4)).fill()
    NSBezierPath(ovalIn: NSRect(x: 39 - 3.2, y: 28 - 3.2, width: 6.4, height: 6.4)).fill()

    ctx.cgContext.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (px, name) in sizes {
    let rep = render(px: px)
    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    let path = "\(outDir)/icon_\(name).png"
    try? data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}
