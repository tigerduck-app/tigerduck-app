import SwiftUI
import Testing
@testable import TigerDuck

@MainActor
struct ScoreColorTests {
    private static let colours = [
        TigerDuckTheme.Tint.green, TigerDuckTheme.Tint.blue, TigerDuckTheme.Tint.yellow, TigerDuckTheme.Tint.coral, TigerDuckTheme.Tint.red, TigerDuckTheme.Tint.grey,
        TigerDuckTheme.Tint.skyBlue, TigerDuckTheme.Tint.teal, TigerDuckTheme.Tint.cyan, TigerDuckTheme.Tint.orange, TigerDuckTheme.Tint.purple,
    ]

    // Badges draw the colour on an 18% fill of itself. The dark page keeps its shades, which pass
    // only the 3:1 for the large, bold figures.
    @Test(
        "Score colours read on their badge fill in both appearances",
        arguments: colours, [(ColorScheme.light, 4.5), (.dark, 3.0)]
    )
    func readsOnCard(colour: Color, appearance: (scheme: ColorScheme, minimum: Double)) {
        var environment = EnvironmentValues()
        environment.colorScheme = appearance.scheme
        let surface = Color.cardSurface.resolve(in: environment)
        let page = Color.backgroundPrimary.resolve(in: environment)
        let card = Self.over(surface, surface.opacity, page)
        let ink = colour.resolve(in: environment)
        let (a, b) = (Self.luminance(ink), Self.luminance(Self.over(ink, 0.18, card)))

        #expect((max(a, b) + 0.05) / (min(a, b) + 0.05) >= appearance.minimum)
    }

    @Test("Letter grades take their band's colour", arguments: [("A+", TigerDuckTheme.Tint.green), ("b-", TigerDuckTheme.Tint.blue), ("C", TigerDuckTheme.Tint.yellow), ("E", TigerDuckTheme.Tint.coral), ("X", Color.textPrimary)])
    func gradeBand(grade: String, colour: Color) {
        #expect(ScoreColor.grade(grade) == colour)
    }

    private static func over(_ top: Color.Resolved, _ share: Float, _ bottom: Color.Resolved) -> Color.Resolved {
        Color.Resolved(
            red: top.red * share + bottom.red * (1 - share),
            green: top.green * share + bottom.green * (1 - share),
            blue: top.blue * share + bottom.blue * (1 - share)
        )
    }

    private static func luminance(_ colour: Color.Resolved) -> Double {
        0.2126 * Double(colour.linearRed) + 0.7152 * Double(colour.linearGreen) + 0.0722 * Double(colour.linearBlue)
    }
}
