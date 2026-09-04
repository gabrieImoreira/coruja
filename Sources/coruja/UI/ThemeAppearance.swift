import AppKit

/// Keeps every open *window's* `.appearance` in sync with the
/// `corujaDarkMode` preference SwiftUI views read via `@AppStorage`. The
/// views themselves never use `.preferredColorScheme`: this hand-rolled
/// `NSApplication` setup (no SwiftUI `App`/`WindowGroup` lifecycle, see
/// Coruja.swift) doesn't reliably propagate that to native AppKit-backed
/// controls hosted inside (the `NSPopUpButton` behind a `.pickerStyle(.menu)`
/// Picker, for one) — confirmed live: the Settings window's "Idioma"
/// dropdown rendered unreadable (black-on-black) right after toggling the
/// theme, only correcting itself later once something else happened to
/// touch the window's appearance.
///
/// Deliberately does NOT set `NSApp.appearance`. Tried that first — it also
/// fixed the dropdown, but broke the menu bar status item's icon: template
/// images are normally tinted by AppKit based on the status bar's own
/// (vibrancy-driven, dynamic) effective appearance, and forcing the whole
/// app's `NSApp.appearance` overrides that per-item vibrancy, hardcoding the
/// glyph to whatever `corujaDarkMode` says regardless of the bar's actual
/// look — confirmed live: the owl stayed black even after switching System
/// Appearance all the way to Dark. Scoping the override to actual windows
/// only fixes the dropdown without touching the status item at all.
enum ThemeAppearance {
    private static let key = "corujaDarkMode"

    @MainActor
    static func install() {
        apply()
        // `@AppStorage` is UserDefaults underneath, so this catches the
        // toggle wherever it's flipped (Settings, or any future surface)
        // without needing a binding threaded through AppController.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            // Already on the main thread (queue: .main above) — apply()
            // synchronously instead of hopping through another Task, so an
            // already-open window's native controls repaint immediately
            // rather than one runloop turn later.
            MainActor.assumeIsolated { apply() }
        }
    }

    @MainActor
    private static func apply() {
        let isDark = UserDefaults.standard.bool(forKey: key)
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        for window in NSApp.windows {
            window.appearance = appearance
        }
    }
}
