import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

extension Color {
    /// AppKit has no direct equivalent; `NSColor.controlBackgroundColor` is the
    /// closest dynamic semantic colour for inset content surfaces in light and
    static var secondarySystemGroupedBackgroundCompat: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }
}

extension Color {
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

    static let backgroundPrimary = Color.black
    static let cardSurface = Color(hex: 0x1E1E1E, alpha: 0.8)
    static let textPrimary = Color.white
    static let textSecondary = Color(hex: 0xFFFFFF, alpha: 0.6)
    static let onboardingAccent = Color(hex: 0x007AFF)
    static let badgeRed = Color(hex: 0xFF3B30)
    static let badgeRedText = Color(hex: 0xFF7A72)
    static let textOnPastel = Color(hex: 0x1A1A1A)
    static let textOnPastelSecondary = Color(hex: 0x1A1A1A, alpha: 0.8)
    static let rowBand = Color.primary.opacity(0.08)
    static let rowBandAlternate = Color.primary.opacity(0.04)

    var pastel: Color { mixed(toward: 1, by: 0.65) }

    var pastelOutline: Color { mixed(toward: 0, by: 0.5) }

    private func mixed(toward target: Float, by share: Float) -> Color {
        var resolved = resolve(in: EnvironmentValues())
        resolved.red += (target - resolved.red) * share
        resolved.green += (target - resolved.green) * share
        resolved.blue += (target - resolved.blue) * share
        resolved.opacity = 1
        return Color(resolved)
    }

    static let moodleBlue = Color(hex: 0x007AFF)
    static let schoolOrange = Color(hex: 0xFF9500)
    static let examRed = Color(hex: 0xFF3B30)
}
