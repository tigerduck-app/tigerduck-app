import SwiftUI

/// The score pages' colours. The light shades are darker versions of the dark page's pastels,
/// which fade on the light cards.
enum ScoreColor {
    static let green = adaptive(light: 0x1E8449, dark: 0x2ECC71)
    static let blue = adaptive(light: 0x2471A3, dark: 0x3498DB)
    static let yellow = adaptive(light: 0x8A6D00, dark: 0xF7DC6F)
    static let coral = adaptive(light: 0xC0392B, dark: 0xFF6B6B)
    static let red = adaptive(light: 0xC0392B, dark: 0xE74C3C)
    static let grey = adaptive(light: 0x627171, dark: 0x95A5A6)
    static let skyBlue = adaptive(light: 0x1F618D, dark: 0x85C1E9)
    static let teal = adaptive(light: 0x0E7C75, dark: 0x4ECDC4)
    static let cyan = adaptive(light: 0x1F7A99, dark: 0x45B7D1)
    static let orange = adaptive(light: 0xB35400, dark: 0xE67E22)
    static let purple = Color(hex: 0x9B59B6)

    static func grade(_ grade: String) -> Color {
        let upper = grade.uppercased()
        if upper.hasPrefix("A") { return green }
        if upper.hasPrefix("B") { return blue }
        if upper.hasPrefix("C") { return yellow }
        if upper.hasPrefix("D") || upper.hasPrefix("E") || upper.hasPrefix("F") { return coral }
        return Color.textPrimary
    }

    private static func adaptive(light: UInt, dark: UInt) -> Color {
        Color.adaptive(light: Color(hex: light), dark: Color(hex: dark))
    }
}
