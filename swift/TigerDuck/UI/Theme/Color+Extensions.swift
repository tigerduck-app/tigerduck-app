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

    nonisolated static func adaptive(light: Color, dark: Color) -> Color {
        #if os(iOS)
        let (light, dark) = (UIColor(light), UIColor(dark))
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
        #else
        let (light, dark) = (NSColor(light), NSColor(dark))
        return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light })
        #endif
    }

    /// The light page is the system's grouped background, so grouped rows and cards stand out on it.
    static let backgroundPrimary = adaptive(light: Color(hex: 0xF2F2F7), dark: .black)
    static let cardSurface = adaptive(light: Color(hex: 0xFFFFFF, alpha: 0.8), dark: Color(hex: 0x1E1E1E, alpha: 0.8))
    static let textPrimary = adaptive(light: .black, dark: .white)
    static let emptyCellFill = adaptive(light: Color.black.opacity(0.05), dark: Color.white.opacity(0.1))
    static let textSecondary = adaptive(light: Color(hex: 0x000000, alpha: 0.6), dark: Color(hex: 0xFFFFFF, alpha: 0.6))
    static let onboardingAccent = Color(hex: 0x007AFF)
    static let badgeRed = Color(hex: 0xFF3B30)
    static let badgeRedText = adaptive(light: Color(hex: 0xD70015), dark: Color(hex: 0xFF7A72))
    /// A value the school changed for one day, such as a moved room or a new start time.
    static let changeInk = adaptive(light: Color(hex: 0x7C2D12), dark: Color(hex: 0xFDBA74))
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

    /// The 24-bit sRGB value of a colour, such as a `ColorPicker`'s pick.
    ///
    /// On macOS, `NSColor(color)` may land in a color space with no direct
    /// `cgColor`: the API is declared non-optional but documented to return
    /// nil then, and the picker's catalog colors trip this. Converting through
    /// `.sRGB` first reads RGBA from a well-defined space, and an unresolved
    /// CGColor becomes black (0) instead of a crash.
    var rgbHex: UInt32 {
        #if canImport(UIKit)
        let resolved: CGColor? = UIColor(self).cgColor
        #elseif canImport(AppKit)
        let resolved: CGColor? = NSColor(self).usingColorSpace(.sRGB)?.cgColor
        #else
        let resolved: CGColor? = nil
        #endif
        guard let cg = resolved else { return 0 }
        let components = cg.components ?? [0, 0, 0, 1]
        let byte = { (index: Int) in
            UInt32((max(0, min(1, components[min(index, components.count - 1)])) * 255).rounded())
        }
        return (byte(0) << 16) | (byte(1) << 8) | byte(2)
    }
}
