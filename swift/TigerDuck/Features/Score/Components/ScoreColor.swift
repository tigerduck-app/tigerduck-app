import SwiftUI

enum ScoreColor {
    static func grade(_ grade: String) -> Color {
        let upper = grade.uppercased()
        if upper.hasPrefix("A") { return TigerDuckTheme.Tint.green }
        if upper.hasPrefix("B") { return TigerDuckTheme.Tint.blue }
        if upper.hasPrefix("C") { return TigerDuckTheme.Tint.yellow }
        if upper.hasPrefix("D") || upper.hasPrefix("E") || upper.hasPrefix("F") {
            return TigerDuckTheme.Tint.coral
        }
        return Color.textPrimary
    }
}
