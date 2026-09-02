import AppKit

/// Small non-activating notification-style panel, shared by every prompt
/// coruja shows unprompted: "record this meeting?", "stop recording?", and
/// "update available". Same shape (icon + title + body + up to two
/// buttons, vibrancy background, rounded corners), different content/
/// position per caller. AppController keeps one instance per logical
/// notification stream (meeting prompts vs. the update prompt) rather than
/// sharing a single instance across all three, since a meeting prompt and
/// the update prompt could plausibly be relevant at the same time.
@MainActor
final class NotificationPanel: NSObject {
    enum Position {
        /// Top-right of `window`'s frame, or the main screen if `window` is
        /// nil or not currently on screen.
        case topRight(of: NSWindow?)
        case bottomRightOfScreen
    }

    private var panel: NSPanel?
    private var dismissTimer: Timer?
    private var onAction: (() -> Void)?
    private var onIgnore: (() -> Void)?

    private static let width: CGFloat = 320
    private static let height: CGFloat = 104

    /// - Parameters:
    ///   - autoDismiss: seconds before the panel auto-dismisses as "ignore",
    ///     or nil to never auto-dismiss (used for the update prompt — a
    ///     decision that consequential shouldn't disappear unattended).
    func show(
        icon: String,
        title: String,
        message: String,
        actionTitle: String,
        ignoreTitle: String = "Ignorar",
        position: Position,
        autoDismiss: TimeInterval? = 25,
        onAction: @escaping () -> Void,
        onIgnore: @escaping () -> Void
    ) {
        dismiss(fired: false) // replace any prompt already showing on this instance
        self.onAction = onAction
        self.onIgnore = onIgnore

        let width = Self.width, height = Self.height
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.level = .floating
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let effect = NSVisualEffectView(frame: panel.contentRect(forFrameRect: panel.frame))
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true

        let iconView = NSImageView(frame: NSRect(x: 16, y: height - 46, width: 22, height: 22))
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
        iconView.contentTintColor = .labelColor
        effect.addSubview(iconView)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.frame = NSRect(x: 48, y: height - 44, width: width - 64, height: 18)
        effect.addSubview(titleLabel)

        let messageLabel = NSTextField(labelWithString: message)
        messageLabel.font = .systemFont(ofSize: 11.5)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 2
        messageLabel.frame = NSRect(x: 48, y: height - 74, width: width - 64, height: 28)
        effect.addSubview(messageLabel)

        // Deliberately no `keyEquivalent = "\r"` on the action button — that
        // would make AppKit paint it as the window's default button (system
        // blue), which clashes with the rest of the app's monochrome UI.
        let actionButton = NSButton(title: actionTitle, target: self, action: #selector(actionTapped))
        actionButton.bezelStyle = .rounded
        actionButton.frame = NSRect(x: width - 92, y: 14, width: 78, height: 26)
        effect.addSubview(actionButton)

        let ignoreButton = NSButton(title: ignoreTitle, target: self, action: #selector(ignoreTapped))
        ignoreButton.bezelStyle = .rounded
        ignoreButton.frame = NSRect(x: width - 180, y: 14, width: 80, height: 26)
        effect.addSubview(ignoreButton)

        panel.contentView = effect
        panel.setFrameOrigin(origin(for: position, size: NSSize(width: width, height: height)))
        panel.orderFrontRegardless()
        self.panel = panel

        if let autoDismiss {
            dismissTimer = Timer.scheduledTimer(withTimeInterval: autoDismiss, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss(fired: true) }
            }
        }
    }

    @objc private func actionTapped() {
        let action = onAction
        dismiss(fired: false)
        action?()
    }

    @objc private func ignoreTapped() {
        dismiss(fired: true)
    }

    private func dismiss(fired: Bool) {
        dismissTimer?.invalidate()
        dismissTimer = nil
        panel?.close()
        panel = nil
        if fired {
            let action = onIgnore
            onAction = nil
            onIgnore = nil
            action?()
        } else {
            onAction = nil
            onIgnore = nil
        }
    }

    private func origin(for position: Position, size: NSSize) -> NSPoint {
        let margin: CGFloat = 12
        switch position {
        case .topRight(let window):
            let frame = window?.frame ?? NSScreen.main?.visibleFrame ?? .zero
            return NSPoint(x: frame.maxX - size.width - margin, y: frame.maxY - size.height - margin)
        case .bottomRightOfScreen:
            let frame = NSScreen.main?.visibleFrame ?? .zero
            return NSPoint(x: frame.maxX - size.width - margin, y: frame.minY + margin)
        }
    }
}
