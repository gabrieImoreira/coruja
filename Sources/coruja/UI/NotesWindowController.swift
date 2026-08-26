import AppKit
import SwiftUI

/// Hosts the notes browser in a normal, closable window. Opened on demand
/// from the menu bar ("Abrir coruja"); AppController decides whether to keep
/// or drop the Dock icon when it closes (kept if a recording is still live).
@MainActor
final class NotesWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    convenience init(
        root: URL,
        status: RecordingStatus,
        onToggleRecording: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "coruja"
        window.center()
        window.contentView = NSHostingView(
            rootView: NotesRootView(
                root: root, status: status,
                onToggleRecording: onToggleRecording,
                onOpenSettings: onOpenSettings
            )
        )
        self.init(window: window)
        window.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
