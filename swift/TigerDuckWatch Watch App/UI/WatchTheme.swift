import SwiftUI

struct WatchTheme: ViewModifier {
    let snapshot: WatchSnapshot?

    func body(content: Content) -> some View {
        content
            .accentColor(accent)
            .environment(\.locale, WatchLanguage(tag: snapshot?.languageTag).locale)
    }

    private var accent: Color {
        let hex = snapshot?.accentHex ?? WatchSnapshot.defaultAccentHex
        return Color(hex: hex) ?? .orange
    }
}

/// A changed room with the small swap glyph in front, as the phone draws it.
struct ChangedRoomLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

extension Color {
    /// A value the school changed for the day; the phone's dark-surface change color.
    static let changeInk = Color(.sRGB, red: 0xFD / 255.0, green: 0xBA / 255.0, blue: 0x74 / 255.0, opacity: 1)

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
