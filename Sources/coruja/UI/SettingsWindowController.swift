import AppKit
import SwiftUI

/// Hosts the settings panel in its own closable window — same pattern as
/// NotesWindowController. A separate window rather than a sheet/tab on the
/// notes window: settings aren't tied to browsing recordings, and this way
/// the menu bar's ⌘, works even with no other window open.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Configurações"
        window.center()
        window.contentView = NSHostingView(rootView: SettingsRootView())
        self.init(window: window)
        window.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
