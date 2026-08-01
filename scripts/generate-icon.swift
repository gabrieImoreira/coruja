#!/usr/bin/env swift
// Generates Packaging/AppIcon.iconset (all required sizes) from an SF Symbol
// on a solid background. Run once; `iconutil` turns the .iconset into .icns.
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

func render(px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let full = NSRect(x: 0, y: 0, width: px, height: px)
    let corner = CGFloat(px) * 0.22
    let bg = NSBezierPath(roundedRect: full, xRadius: corner, yRadius: corner)
    NSColor(calibratedRed: 0.06, green: 0.55, blue: 0.45, alpha: 1.0).setFill()
    bg.fill()

    let symbolConfig = NSImage.SymbolConfiguration(pointSize: CGFloat(px) * 0.56, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
        .withSymbolConfiguration(symbolConfig)
    {
        let size = symbol.size
        let rect = NSRect(
            x: (CGFloat(px) - size.width) / 2,
            y: (CGFloat(px) - size.height) / 2,
            width: size.width, height: size.height
        )
        symbol.draw(in: rect)
    }

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
