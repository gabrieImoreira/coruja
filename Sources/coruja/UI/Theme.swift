import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// Design tokens from the "Janela Principal" handoff — a monochrome palette
/// (near-black/white/gray, no warm tones) with light and dark variants.
/// Recording red is the one deliberate accent, unchanged between themes.
struct Theme {
    let isDark: Bool

    static let recordRed = Color(hex: 0xD92D20)

    var windowBg: Color { isDark ? Color(hex: 0x1E1E1E) : Color(hex: 0xFAFAF9) }
    var titlebarBg: Color { isDark ? Color(hex: 0x242424) : Color(hex: 0xF1F1EF) }
    var sidebarBg: Color { titlebarBg }
    var border: Color { isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.08) }

    var pathColor: Color { isDark ? .white.opacity(0.4) : .black.opacity(0.4) }
    var metaColor: Color { pathColor }
    var groupLabelColor: Color { isDark ? .white.opacity(0.35) : .black.opacity(0.38) }

    var rowTitleColor: Color { isDark ? Color(hex: 0xF2F2F0) : Color(hex: 0x1A1A1A) }
    var rowStatusColor: Color { isDark ? .white.opacity(0.55) : .black.opacity(0.55) }
    var rowDurationColor: Color { isDark ? .white.opacity(0.35) : .black.opacity(0.35) }
    var rowSelectedBg: Color { isDark ? Color(hex: 0x333331) : Color(hex: 0xEFEFED) }

    var dotOn: Color { rowTitleColor }
    var dotOff: Color { isDark ? Color(hex: 0x6E6E6B) : Color(hex: 0x9A9A97) }

    var headerTitleColor: Color { rowTitleColor }
    var bodyColor: Color { isDark ? Color(hex: 0xE8E8E6) : Color(hex: 0x1A1A1A) }
    var fallbackColor: Color { isDark ? .white.opacity(0.45) : .black.opacity(0.45) }

    var playerCardBg: Color { isDark ? Color(hex: 0x2A2A2A) : .white }
    var playButtonBg: Color { isDark ? Color(hex: 0xF2F2F0) : Color(hex: 0x1A1A1A) }
    var playIconColor: Color { isDark ? Color(hex: 0x1A1A1A) : Color(hex: 0xFAFAF9) }
    var timeColor: Color { isDark ? .white.opacity(0.45) : .black.opacity(0.45) }
    var scrubTrack: Color { isDark ? Color.white.opacity(0.16) : Color.black.opacity(0.12) }

    var speakerMe: Color { rowTitleColor }
    var speakerOther: Color { isDark ? .white.opacity(0.5) : .black.opacity(0.5) }
    var timestampColor: Color { isDark ? .white.opacity(0.32) : .black.opacity(0.32) }

    var actionBtnBg: Color { playerCardBg }
    var actionBtnColor: Color { rowTitleColor }
    var deleteColor: Color { isDark ? Color(hex: 0xFF6B61) : Color(hex: 0xD92D20) }

    /// The record button's *idle* state is a filled pill inverted per theme
    /// (dark pill on light backgrounds, light pill on dark) — recording
    /// itself is always the same red regardless of theme.
    var recordIdleBg: Color { rowTitleColor }
    var recordIdleColor: Color { isDark ? Color(hex: 0x1A1A1A) : .white }
}
