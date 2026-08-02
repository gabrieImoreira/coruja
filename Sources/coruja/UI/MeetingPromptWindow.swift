import AppKit

/// Small non-activating panel in the top-right corner asking whether to
/// record a just-detected meeting. Non-activating so it never steals focus
/// or space-switches away from the meeting window; auto-dismisses (as
/// "ignore") so an unanswered prompt doesn't linger forever.
@MainActor
final class MeetingPromptWindow: NSObject {
    private var panel: NSPanel?
    private var dismissTimer: Timer?
    private var onRecord: (() -> Void)?
    private var onIgnore: (() -> Void)?

    private static let autoDismiss: TimeInterval = 25

    func show(onRecord: @escaping () -> Void, onIgnore: @escaping () -> Void) {
        dismiss(fired: false) // replace any prompt already showing
        self.onRecord = onRecord
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

        let label = NSTextField(labelWithString: "Reunião detectada no Chrome.\nGravar com a Coruja?")
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        label.frame = NSRect(x: 14, y: height - 54, width: width - 28, height: 36)
        content.addSubview(label)

        let recordButton = NSButton(title: "Gravar", target: self, action: #selector(recordTapped))
        recordButton.bezelStyle = .rounded
        recordButton.keyEquivalent = "\r"
        recordButton.frame = NSRect(x: width - 88, y: 12, width: 76, height: 28)
        content.addSubview(recordButton)

        let ignoreButton = NSButton(title: "Ignorar", target: self, action: #selector(ignoreTapped))
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

    @objc private func recordTapped() {
        let action = onRecord
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
            onRecord = nil
            onIgnore = nil
            action?()
        } else {
            onRecord = nil
            onIgnore = nil
        }
    }
}
