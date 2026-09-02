import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory` — no dock icon, no main window).
@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let stateLabel: NSMenuItem
    private let transcriptionLabel: NSMenuItem
    private let toggleItem: NSMenuItem

    var onToggle: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onOpenNotes: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.autoenablesItems = false

        stateLabel = NSMenuItem(title: "ocioso", action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        transcriptionLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        transcriptionLabel.isEnabled = false
        transcriptionLabel.isHidden = true
        menu.addItem(transcriptionLabel)

        menu.addItem(.separator())

        let openNotes = NSMenuItem(
            title: "Abrir a coruja",
            action: #selector(openNotesClicked),
            keyEquivalent: "n"
        )
        menu.addItem(openNotes)

        toggleItem = NSMenuItem(
            title: "Iniciar gravação",
            action: #selector(toggleClicked),
            keyEquivalent: "r"
        )
        menu.addItem(toggleItem)

        let openFolder = NSMenuItem(
            title: "Abrir pasta de gravações",
            action: #selector(openFolderClicked),
            keyEquivalent: "o"
        )
        menu.addItem(openFolder)

        menu.addItem(.separator())

        let openSettings = NSMenuItem(
            title: "Configurações…",
            action: #selector(openSettingsClicked),
            keyEquivalent: ","
        )
        menu.addItem(openSettings)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Sair da coruja",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        for item in [openNotes, toggleItem, openFolder, openSettings, quit] {
            item.target = self
        }

        statusItem.menu = menu

        if let button = statusItem.button {
            button.image = Self.brandIcon()
            button.imagePosition = .imageLeft
        }
    }

    /// Reflect recording state in the icon tint and menu item titles. The
    /// menu bar shows only the waveform icon (red while recording); the
    /// elapsed counter lives in the menu's state label. Call once a second
    /// while recording.
    func update(recording: Bool, elapsed: String?) {
        stateLabel.title = recording ? "● gravando · \(elapsed ?? "0:00")" : "ocioso"
        toggleItem.title = recording ? "Parar gravação" : "Iniciar gravação"
        statusItem.button?.contentTintColor = recording ? .systemRed : nil
    }

    /// Show transcription progress/failure as a second status line in the
    /// menu; nil hides it. Independent of recording state — a new recording
    /// can run while the last one transcribes.
    func updateTranscription(_ text: String?) {
        transcriptionLabel.title = text ?? ""
        transcriptionLabel.isHidden = text == nil
    }

    /// The coruja silhouette for the status item. Drawn directly instead of
    /// loading a bundled PNG — a rasterized-from-SVG asset came back with
    /// its transparency flattened onto opaque white (confirmed live —
    /// rendered as a solid white square in the menu bar).
    ///
    /// Built against an explicit 8-bit sRGB `NSBitmapImageRep` rather than
    /// `lockFocus()` — an earlier lockFocus-based version produced pixel-
    /// perfect data (verified by sampling: opaque black head, transparent
    /// eyes) but rendered as an invisible status item live; this explicit-
    /// bitmap version is confirmed working in the real menu bar. `.clear`
    /// compositing punches real alpha holes for the eyes, which is what
    /// `isTemplate` needs outside the owl shape.
    ///
    /// "Clássica" mark — same outline as `Packaging/AppIcon.icns` (see
    /// `scripts/generate-icon.swift`), so the menu bar glyph and the Dock
    /// icon are the same owl at two sizes, not two different drawings.
    private static func brandIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let scale = 2 // one fixed backing resolution; AppKit downscales for @1x displays
        let pixelSize = Int(size.width) * scale

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

        // Map the owl's 64x64 SVG-style space (origin top-left, y down) onto
        // this bottom-up pixel canvas — same transform trick as the icon
        // generation script.
        let canvas = CGFloat(pixelSize)
        let contentSize = canvas * 0.94
        let margin = (canvas - contentSize) / 2
        let ownScale = contentSize / 64
        ctx.cgContext.translateBy(x: margin, y: canvas - margin)
        ctx.cgContext.scaleBy(x: ownScale, y: -ownScale)

        NSColor.black.setFill()
        Self.owlOutline().fill()
        Self.rotatedEllipse(cx: 19, cy: 9, rx: 4.2, ry: 7.5, degrees: -24).fill()
        Self.rotatedEllipse(cx: 45, cy: 9, rx: 4.2, ry: 7.5, degrees: 24).fill()

        ctx.compositingOperation = .clear
        NSBezierPath(ovalIn: NSRect(x: 15, y: 18, width: 20, height: 20)).fill()
        NSBezierPath(ovalIn: NSRect(x: 29, y: 18, width: 20, height: 20)).fill()
        ctx.compositingOperation = .sourceOver

        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: 21.8, y: 24.8, width: 6.4, height: 6.4)).fill()
        NSBezierPath(ovalIn: NSRect(x: 35.8, y: 24.8, width: 6.4, height: 6.4)).fill()

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }

    /// The owl's outline in a 64x64 SVG-style coordinate space (origin
    /// top-left, y grows downward).
    private static func owlOutline() -> NSBezierPath {
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

    private static func rotatedEllipse(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat, degrees: CGFloat) -> NSBezierPath {
        let oval = NSBezierPath(ovalIn: NSRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2))
        var transform = AffineTransform.identity
        transform.translate(x: cx, y: cy)
        transform.rotate(byDegrees: degrees)
        oval.transform(using: transform)
        return oval
    }

    @objc private func toggleClicked() { onToggle?() }
    @objc private func openFolderClicked() { onOpenFolder?() }
    @objc private func openNotesClicked() { onOpenNotes?() }
    @objc private func openSettingsClicked() { onOpenSettings?() }
    @objc private func quitClicked() { onQuit?() }
}
