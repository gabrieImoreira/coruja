import AppKit

/// Keeps AppKit's actual appearance — `NSApp.appearance` and every open
/// window's `.appearance` — in sync with the `corujaDarkMode` preference
/// SwiftUI views read via `@AppStorage`. The views themselves never use
/// `.preferredColorScheme`: this hand-rolled `NSApplication` setup (no
/// SwiftUI `App`/`WindowGroup` lifecycle, see Coruja.swift) doesn't
/// reliably propagate that to native AppKit-backed controls hosted inside
/// (the `NSPopUpButton` behind a `.pickerStyle(.menu)` Picker, for one) —
/// confirmed live: the Settings window's "Idioma" dropdown rendered
/// unreadable (black-on-black) right after toggling the theme, only
/// correcting itself later once something else happened to touch the
/// window's appearance. Setting `window.appearance` directly, synchronously,
/// the moment the toggle flips is what actually closes that race — the
/// notification-only `NSApp.appearance` version left already-open windows
/// stale until macOS got around to reapplying it on its own schedule.
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
        NSApp.appearance = appearance
        for window in NSApp.windows {
            window.appearance = appearance
        }
    }
}
