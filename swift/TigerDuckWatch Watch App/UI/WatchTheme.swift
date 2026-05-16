import SwiftUI

/// Root-level modifier that applies the phone-pushed accent colour + locale.
/// Use as `.modifier(WatchTheme(snapshot: store.snapshot))` on the root view.
struct WatchTheme: ViewModifier {
    let snapshot: WatchSnapshot?

    func body(content: Content) -> some View {
        content
            .accentColor(accent)
            .environment(\.locale, locale)
    }

    private var accent: Color {
        let hex = snapshot?.accentHex ?? WatchSnapshot.defaultAccentHex
        return Color(hex: hex) ?? .orange
    }

    private var locale: Locale {
        if let tag = snapshot?.languageTag {
            return Locale(identifier: tag)
        }
        return .current
    }
}

extension Color {
    /// Parse "#RRGGBB" or "#AARRGGBB". Returns nil on malformed input.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard let n = UInt32(s, radix: 16) else { return nil }
        switch s.count {
        case 6:
            let r = Double((n >> 16) & 0xFF) / 255.0
            let g = Double((n >>  8) & 0xFF) / 255.0
            let b = Double( n        & 0xFF) / 255.0
            self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
        case 8:
            let a = Double((n >> 24) & 0xFF) / 255.0
            let r = Double((n >> 16) & 0xFF) / 255.0
            let g = Double((n >>  8) & 0xFF) / 255.0
            let b = Double( n        & 0xFF) / 255.0
            self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
        default:
            return nil
        }
    }
}
