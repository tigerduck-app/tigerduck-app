import SwiftUI
import WidgetKit

struct WidgetPalette {
    let background: Color
    let surface: Color
    let onSurface: Color
    let onSurfaceVariant: Color
    let emptyCell: Color
    let highlight: Color
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
        highlight: .blue,
        isFullColor: true
    )

    private static let dark = WidgetPalette(
        background: Color(widgetHex: 0x1C1C1E),
        surface: Color(widgetHex: 0x2C2C2E),
        onSurface: Color(widgetHex: 0xF5F5F5),
        onSurfaceVariant: Color(widgetHex: 0x8E8E93),
        emptyCell: Color(widgetHex: 0x2C2C2E),
        highlight: .blue,
        isFullColor: true
    )
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
