import AppKit

/// Shared owl silhouette — the "Clássica" mark, same outline as
/// `Packaging/AppIcon.icns` (see `scripts/generate-icon.swift`) — used
/// wherever the app draws its own mark instead of loading a bundled asset.
/// `MenuBarController` renders it as an `isTemplate` bitmap for the status
/// item; `image(pixelSize:ink:)` here renders a plain flat silhouette with
/// a fully transparent background (no box, no border) for use directly in
/// SwiftUI views.
enum OwlMark {
    /// Flat `ink`-colored silhouette, transparent everywhere else
    /// (background and the eye-mask cutout), so it composites naturally
    /// onto whatever the caller places it on.
    static func image(pixelSize: Int, ink: NSColor = .black) -> NSImage {
        let size = NSSize(width: pixelSize, height: pixelSize)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize, pixelsHigh: pixelSize,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            return NSImage(size: size)
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx

        let canvas = CGFloat(pixelSize)
        let contentSize = canvas * 0.94
        let margin = (canvas - contentSize) / 2
        let scale = contentSize / 64
        ctx.cgContext.translateBy(x: margin, y: canvas - margin)
        ctx.cgContext.scaleBy(x: scale, y: -scale)

        ink.setFill()
        outline().fill()
        rotatedEllipse(cx: 19, cy: 9, rx: 4.2, ry: 7.5, degrees: -24).fill()
        rotatedEllipse(cx: 45, cy: 9, rx: 4.2, ry: 7.5, degrees: 24).fill()

        ctx.compositingOperation = .clear
        NSBezierPath(ovalIn: NSRect(x: 15, y: 18, width: 20, height: 20)).fill()
        NSBezierPath(ovalIn: NSRect(x: 29, y: 18, width: 20, height: 20)).fill()
        ctx.compositingOperation = .sourceOver

        ink.setFill()
        NSBezierPath(ovalIn: NSRect(x: 21.8, y: 24.8, width: 6.4, height: 6.4)).fill()
        NSBezierPath(ovalIn: NSRect(x: 35.8, y: 24.8, width: 6.4, height: 6.4)).fill()

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    /// The owl's outline in a 64x64 SVG-style coordinate space (origin
    /// top-left, y grows downward).
    static func outline() -> NSBezierPath {
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

    static func rotatedEllipse(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat, degrees: CGFloat) -> NSBezierPath {
        let oval = NSBezierPath(ovalIn: NSRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2))
        var transform = AffineTransform.identity
        transform.translate(x: cx, y: cy)
        transform.rotate(byDegrees: degrees)
        oval.transform(using: transform)
        return oval
    }
}
