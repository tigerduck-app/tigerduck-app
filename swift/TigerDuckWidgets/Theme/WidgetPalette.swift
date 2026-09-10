import SwiftUI
import WidgetKit

/// Color tokens for the widget extension. Light/dark variants are picked from
/// `colorScheme` at render time; `highlight` is overlayed from the snapshot's
/// accent color so widgets follow the user's theme choice.
///
/// The surface tokens are also rendering-mode aware. Outside `.fullColor` the
/// system is compositing the widget over its own material — a tinted home
/// screen, clear glass — and expects the widget to contribute *content*, not
/// surfaces. `containerBackground` is the one background it knows how to strip
/// on its own; a `.fill()` or `.background()` inside the view is ordinary
/// drawing it cannot see, so an opaque token there survives as a solid block
/// floating on the glass. Resolving them to clear here fixes every call site at
/// once, and keeps the branch out of the views.
struct WidgetPalette {
    let background: Color
    let surface: Color
    let onSurface: Color
    let onSurfaceVariant: Color
    let emptyCell: Color
    let highlight: Color
    /// Views that build their own fills (rather than reading a token) branch on
    /// this — see `TodayListView.row`, whose ongoing row is painted from the
    /// course color rather than from `surface`.
    let isFullColor: Bool

    static func resolve(
        snapshot: WidgetSnapshot,
        colorScheme: ColorScheme,
        renderingMode: WidgetRenderingMode = .fullColor
    ) -> WidgetPalette {
        let base = colorScheme == .dark ? Self.dark : Self.light
        let isFullColor = renderingMode == .fullColor
        return WidgetPalette(
            background: isFullColor ? base.background : .clear,
            surface: isFullColor ? base.surface : .clear,
            onSurface: base.onSurface,
            onSurfaceVariant: base.onSurfaceVariant,
            // Not clear: a timetable with no cell structure is a field of
            // floating labels, and the grid is most of what makes it readable
            // at a glance. A low-alpha wash keeps the ruling visible while
            // still letting the material through, and the system tints it
            // along with everything else.
            emptyCell: isFullColor ? base.emptyCell : Color.white.opacity(0.10),
            highlight: Color(widgetHex: snapshot.accentColorHex),
            isFullColor: isFullColor
        )
    }

    private static let light = WidgetPalette(
        background: Color(widgetHex: 0xF5F5F5),
        surface: Color(widgetHex: 0xFFFFFF),
        onSurface: Color(widgetHex: 0x1C1C1E),
        onSurfaceVariant: Color(widgetHex: 0x6E6E73),
        emptyCell: Color(widgetHex: 0xECECEC),
        highlight: .blue,  // overridden by resolve()
        isFullColor: true  // ditto
    )

    private static let dark = WidgetPalette(
        background: Color(widgetHex: 0x1C1C1E),
        surface: Color(widgetHex: 0x2C2C2E),
        onSurface: Color(widgetHex: 0xF5F5F5),
        onSurfaceVariant: Color(widgetHex: 0x8E8E93),
        emptyCell: Color(widgetHex: 0x2C2C2E),
        highlight: .blue,  // overridden by resolve()
        isFullColor: true  // ditto
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
