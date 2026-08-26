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
        ctx.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: 4.2, y: 5.6, width: 9.6, height: 9.6)).fill()

        let earL = NSBezierPath()
        earL.move(to: NSPoint(x: 5.4, y: 13.0))
        earL.line(to: NSPoint(x: 4.3, y: 16.4))
        earL.line(to: NSPoint(x: 7.2, y: 12.5))
        earL.close()
        earL.fill()

        let earR = NSBezierPath()
        earR.move(to: NSPoint(x: 12.6, y: 13.0))
        earR.line(to: NSPoint(x: 13.7, y: 16.4))
        earR.line(to: NSPoint(x: 10.8, y: 12.5))
        earR.close()
        earR.fill()

        ctx.compositingOperation = .clear
        NSBezierPath(ovalIn: NSRect(x: 6.0, y: 8.3, width: 2.6, height: 2.6)).fill()
        NSBezierPath(ovalIn: NSRect(x: 9.4, y: 8.3, width: 2.6, height: 2.6)).fill()
        ctx.compositingOperation = .sourceOver

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }

    @objc private func toggleClicked() { onToggle?() }
    @objc private func openFolderClicked() { onOpenFolder?() }
    @objc private func openNotesClicked() { onOpenNotes?() }
    @objc private func openSettingsClicked() { onOpenSettings?() }
    @objc private func quitClicked() { onQuit?() }
}
