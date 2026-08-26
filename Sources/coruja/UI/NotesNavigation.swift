import Foundation

/// Which screen the notes window shows — settings lives inside the same
/// window as a full-screen swap with a back button, not a separate window
/// (a single window for the whole app, like most ordinary Mac apps).
/// Shared with AppController so the menu bar's "Configurações…" (⌘,) can
/// jump straight to the settings screen even if the window is already open
/// on the session list, or wasn't open at all yet.
@MainActor
final class NotesNavigation: ObservableObject {
    @Published var showingSettings = false
}
