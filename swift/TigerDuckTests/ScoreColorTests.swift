import SwiftUI
import Testing
@testable import TigerDuck

@MainActor
struct ScoreColorTests {
    private static let colours = [
        ScoreColor.green, ScoreColor.blue, ScoreColor.yellow, ScoreColor.coral, ScoreColor.red, ScoreColor.grey,
        ScoreColor.skyBlue, ScoreColor.teal, ScoreColor.cyan, ScoreColor.orange, ScoreColor.purple,
    ]

    // The dark page keeps its shades, which pass only the 3:1 for the large, bold figures.
    @Test(
        "Score colours read on the cards in both appearances",
        arguments: colours, [(ColorScheme.light, 4.5), (.dark, 3.0)]
    )
    func readsOnCard(colour: Color, appearance: (scheme: ColorScheme, minimum: Double)) {
        var environment = EnvironmentValues()
        environment.colorScheme = appearance.scheme
        let surface = Color.cardSurface.resolve(in: environment)
        let page = Color.backgroundPrimary.resolve(in: environment)
        let card = Color.Resolved(
            red: surface.red * surface.opacity + page.red * (1 - surface.opacity),
            green: surface.green * surface.opacity + page.green * (1 - surface.opacity),
            blue: surface.blue * surface.opacity + page.blue * (1 - surface.opacity)
        )
        let (a, b) = (Self.luminance(colour.resolve(in: environment)), Self.luminance(card))

        #expect((max(a, b) + 0.05) / (min(a, b) + 0.05) >= appearance.minimum)
    }

    @Test("Letter grades take their band's colour", arguments: [("A+", ScoreColor.green), ("b-", ScoreColor.blue), ("C", ScoreColor.yellow), ("E", ScoreColor.coral), ("X", Color.textPrimary)])
    func gradeBand(grade: String, colour: Color) {
        #expect(ScoreColor.grade(grade) == colour)
    }

    private static func luminance(_ colour: Color.Resolved) -> Double {
        0.2126 * Double(colour.linearRed) + 0.7152 * Double(colour.linearGreen) + 0.0722 * Double(colour.linearBlue)
    }
}
