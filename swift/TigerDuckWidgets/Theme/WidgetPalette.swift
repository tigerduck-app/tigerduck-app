import SwiftUI
import WidgetKit

/// Outside `.fullColor` the system composites the widget over its own material (a tinted home
/// screen, clear glass) and expects content, not surfaces. It strips only `containerBackground`;
/// a `.fill()` or `.background()` in a view is drawing it cannot see, so an opaque token there
/// stays a solid block on the glass. The surface tokens resolve to clear in those modes, which
/// fixes every call site at once and keeps the branch out of the views.
struct WidgetPalette {
    let background: Color
    let onSurface: Color
    let onSurfaceVariant: Color
    let highlight: Color
    let changeInk: Color
    let isFullColor: Bool
    var canvas: Color = .clear
    var isDark = false

    static func resolve(
        snapshot: WidgetSnapshot,
        colorScheme: ColorScheme,
        renderingMode: WidgetRenderingMode = .fullColor
    ) -> WidgetPalette {
        let base = colorScheme == .dark ? Self.dark : Self.light
        let isFullColor = renderingMode == .fullColor
        return WidgetPalette(
            background: isFullColor ? base.background : .clear,
            onSurface: base.onSurface,
            onSurfaceVariant: base.onSurfaceVariant,
            highlight: Color(widgetHex: snapshot.accentColorHex),
            changeInk: base.changeInk,
            isFullColor: isFullColor,
            canvas: isFullColor ? base.canvas : .clear,
            isDark: base.isDark
        )
    }

    func tile(_ colorHex: UInt32, isPast: Bool = false) -> WidgetTile {
        guard isFullColor else {
            return WidgetTile(
                fill: .white.opacity(isPast ? 0.07 : 0.14),
                ink: isPast ? .white.opacity(0.7) : .white,
                secondaryInk: .white.opacity(isPast ? 0.7 : 0.85),
                accent: .white,
                track: .white.opacity(0.25)
            )
        }
        let course = Color(widgetHex: colorHex)
        let fill = isDark ? course.darkPastel : course.pastel
        let ink = isDark ? onSurface : Color.textOnPastel
        let secondary = isDark ? onSurface.opacity(0.85) : Color.textOnPastelSecondary
        return WidgetTile(
            fill: isPast ? fill.opacity(0.4) : fill,
            ink: isPast ? onSurfaceVariant : ink,
            secondaryInk: isPast ? onSurfaceVariant : secondary,
            accent: isDark ? course : course.pastelOutline,
            track: isDark ? .white.opacity(0.2) : Color.textOnPastel.opacity(0.14),
            base: isPast ? canvas : .clear
        )
    }

    private static let light = WidgetPalette(
        background: Color(widgetHex: 0xF5F5F5),
        onSurface: Color(widgetHex: 0x1C1C1E),
        onSurfaceVariant: Color(widgetHex: 0x6E6E73),
        highlight: .blue,
        changeInk: Color(widgetHex: 0x7C2D12),
        isFullColor: true,
        canvas: .white
    )

    private static let dark = WidgetPalette(
        background: Color(widgetHex: 0x1C1C1E),
        onSurface: Color(widgetHex: 0xF5F5F5),
        onSurfaceVariant: Color(widgetHex: 0xA1A1A6),
        highlight: .blue,
        changeInk: Color(widgetHex: 0xFDBA74),
        isFullColor: true,
        canvas: Color(widgetHex: 0x1C1C1E),
        isDark: true
    )
}

struct WidgetTile {
    let fill: Color
    let ink: Color
    let secondaryInk: Color
    let accent: Color
    let track: Color
    var base: Color = .clear
}

extension Color {
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
