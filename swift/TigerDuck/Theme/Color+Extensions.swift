import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

extension Color {
    /// Cross-platform analogue of `UIColor.secondarySystemGroupedBackground`,
    /// the iOS colour that lifts inset cards above `systemGroupedBackground`.
    ///
    /// AppKit has no direct equivalent; `NSColor.controlBackgroundColor` is the
    /// closest dynamic semantic colour for inset content surfaces in light and
    /// dark mode. It looks the same as iOS at first glance; per-mode tuning can
    /// swap in a custom asset later without touching call sites.
    static var secondarySystemGroupedBackgroundCompat: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }
}

extension Color {
    /// Initialise from a 24-bit RGB integer. Higher bits are masked off so
    /// values >0xFFFFFF can't push channels above 1.0.
    init(hex: UInt, alpha: Double = 1.0) {
        let masked = hex & 0xFFFFFF
        self.init(
            .sRGB,
            red: Double((masked >> 16) & 0xFF) / 255,
            green: Double((masked >> 8) & 0xFF) / 255,
            blue: Double(masked & 0xFF) / 255,
            opacity: alpha
        )
    }

    // MARK: - App Colors

    static let backgroundPrimary = Color.black
    static let cardSurface = Color(hex: 0x1E1E1E, alpha: 0.8)
    static let textPrimary = Color.white
    static let textSecondary = Color(hex: 0xFFFFFF, alpha: 0.6)
    /// Fixed on purpose: onboarding runs before a theme is chosen, and its
    /// pages carry their own per-page colours rather than the app tint.
    static let onboardingAccent = Color(hex: 0x007AFF)
    static let badgeRed = Color(hex: 0xFF3B30)
    /// Text on a ``pastel`` fill, which stays light in either appearance.
    static let textOnPastel = Color(hex: 0x1A1A1A)
    static let textOnPastelSecondary = Color(hex: 0x1A1A1A, alpha: 0.8)
    /// The two tones of a grid's alternating row bands.
    static let rowBand = Color.primary.opacity(0.08)
    static let rowBandAlternate = Color.primary.opacity(0.04)

    /// This colour mixed with white into an opaque pastel. Mixing with white keeps the hue, so a
    /// course still shows the colour it was given, and lifts every channel to at least 65%, where
    /// ``textOnPastel`` reads at better than 7:1.
    var pastel: Color { mixed(toward: 1, by: 0.65) }

    /// This colour mixed half with black, for a line on its own ``pastel`` that stands out from
    /// it at better than 3:1 whatever the colour.
    var pastelOutline: Color { mixed(toward: 0, by: 0.5) }

    /// Each sRGB channel moved `share` of the way to `target`, opaque.
    private func mixed(toward target: Float, by share: Float) -> Color {
        var resolved = resolve(in: EnvironmentValues())
        resolved.red += (target - resolved.red) * share
        resolved.green += (target - resolved.green) * share
        resolved.blue += (target - resolved.blue) * share
        resolved.opacity = 1
        return Color(resolved)
    }

    // MARK: - Calendar Event Colors

    static let moodleBlue = Color(hex: 0x007AFF)
    static let schoolOrange = Color(hex: 0xFF9500)
    static let examRed = Color(hex: 0xFF3B30)
}
