import SwiftUI

/// Color tokens for the widget extension. Light/dark variants are picked from
/// `colorScheme` at render time; `highlight` is overlayed from the snapshot's
/// accent color so widgets follow the user's theme choice.
struct WidgetPalette {
    let background: Color
    let surface: Color
    let onSurface: Color
    let onSurfaceVariant: Color
    let emptyCell: Color
    let highlight: Color

    static func resolve(snapshot: WidgetSnapshot, colorScheme: ColorScheme) -> WidgetPalette {
        let base = colorScheme == .dark ? Self.dark : Self.light
        return WidgetPalette(
            background: base.background,
            surface: base.surface,
            onSurface: base.onSurface,
            onSurfaceVariant: base.onSurfaceVariant,
            emptyCell: base.emptyCell,
            highlight: Color(widgetHex: snapshot.accentColorHex)
        )
    }

    private static let light = WidgetPalette(
        background: Color(widgetHex: 0xF5F5F5),
        surface: Color(widgetHex: 0xFFFFFF),
        onSurface: Color(widgetHex: 0x1C1C1E),
        onSurfaceVariant: Color(widgetHex: 0x6E6E73),
        emptyCell: Color(widgetHex: 0xECECEC),
        highlight: .blue   // overridden by resolve()
    )

    private static let dark = WidgetPalette(
        background: Color(widgetHex: 0x1C1C1E),
        surface: Color(widgetHex: 0x2C2C2E),
        onSurface: Color(widgetHex: 0xF5F5F5),
        onSurfaceVariant: Color(widgetHex: 0x8E8E93),
        emptyCell: Color(widgetHex: 0x2C2C2E),
        highlight: .blue   // overridden by resolve()
    )
}

extension Color {
    /// 24-bit RGB initializer scoped to the widget extension.
    /// The main app has `Color(hex: UInt, alpha: Double = 1.0)` in
    /// `Theme/Color+Extensions.swift` but that file is not (and should not be)
    /// a member of the widget target — adding the whole theme would drag in
    /// the app's domain types. We define a `UInt32` overload here under a
    /// distinct argument label (`widgetHex`) so the call sites in this file
    /// resolve unambiguously and any future addition of the theme file to
    /// the widget target won't conflict on overload resolution.
    init(widgetHex: UInt32) {
        let masked = widgetHex & 0xFFFFFF
        self.init(
            .sRGB,
            red: Double((masked >> 16) & 0xFF) / 255,
            green: Double((masked >> 8) & 0xFF) / 255,
            blue: Double(masked & 0xFF) / 255,
            opacity: 1
        )
    }
}
