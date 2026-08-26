import AppKit

/// Small non-activating panel in the top-right corner, used for both
/// meeting-lifecycle prompts coruja shows unprompted: "a meeting just
/// started in Chrome, record it?" and "that meeting just ended, stop
/// recording?" — same shape, different message/buttons. Non-activating so
/// it never steals focus or space-switches away from the meeting window;
/// auto-dismisses (as "ignore") so an unanswered prompt doesn't linger
/// forever. One shared instance handles either prompt, never both at once —
/// showing a new one replaces whatever was already up.
@MainActor
final class MeetingPromptWindow: NSObject {
    private var panel: NSPanel?
    private var dismissTimer: Timer?
    private var onAction: (() -> Void)?
    private var onIgnore: (() -> Void)?

    private static let autoDismiss: TimeInterval = 25

    func show(
        message: String,
        actionTitle: String,
        ignoreTitle: String = "Ignorar",
        onAction: @escaping () -> Void,
        onIgnore: @escaping () -> Void
    ) {
        dismiss(fired: false) // replace any prompt already showing
        self.onAction = onAction
        self.onIgnore = onIgnore

        let width: CGFloat = 300, height: CGFloat = 92
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
        panel.backgroundColor = .windowBackgroundColor
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        content.wantsLayer = true

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        label.frame = NSRect(x: 14, y: height - 54, width: width - 28, height: 36)
        content.addSubview(label)

        let actionButton = NSButton(title: actionTitle, target: self, action: #selector(actionTapped))
        actionButton.bezelStyle = .rounded
        actionButton.keyEquivalent = "\r"
        actionButton.frame = NSRect(x: width - 88, y: 12, width: 76, height: 28)
        content.addSubview(actionButton)

        let ignoreButton = NSButton(title: ignoreTitle, target: self, action: #selector(ignoreTapped))
        ignoreButton.bezelStyle = .rounded
        ignoreButton.frame = NSRect(x: width - 172, y: 12, width: 76, height: 28)
        content.addSubview(ignoreButton)

        panel.contentView = content

        if let screen = NSScreen.main {
            let margin: CGFloat = 12
            let origin = NSPoint(
                x: screen.visibleFrame.maxX - width - margin,
                y: screen.visibleFrame.maxY - height - margin
            )
            panel.setFrameOrigin(origin)
        }

        panel.orderFrontRegardless()
        self.panel = panel

        dismissTimer = Timer.scheduledTimer(withTimeInterval: Self.autoDismiss, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(fired: true) }
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
}
