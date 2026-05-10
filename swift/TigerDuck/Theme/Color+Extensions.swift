import SwiftUI

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
    static let accentPrimary = Color(hex: 0x007AFF)
    static let badgeRed = Color(hex: 0xFF3B30)

    // MARK: - Calendar Event Colors

    static let moodleBlue = Color(hex: 0x007AFF)
    static let schoolOrange = Color(hex: 0xFF9500)
    static let examRed = Color(hex: 0xFF3B30)
}
