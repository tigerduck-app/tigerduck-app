import SwiftUI
import Testing
@testable import TigerDuck

@MainActor
struct CustomAccentTests {
    @Test("The cards a custom accent is checked on are the card surface over the black page")
    func cardMatchesTheTheme() {
        let surface = Color.cardSurface.resolve(in: EnvironmentValues())
        let page = Color.backgroundPrimary.resolve(in: EnvironmentValues())
        let card = Color(Color.Resolved(
            red: surface.red * surface.opacity + page.red * (1 - surface.opacity),
            green: surface.green * surface.opacity + page.green * (1 - surface.opacity),
            blue: surface.blue * surface.opacity + page.blue * (1 - surface.opacity)
        ))

        #expect(card.rgbHex == UInt32(AppState.accentCardHex))
    }

    @Test(
        "A custom accent reads on the cards and under white marks",
        arguments: [0x000000, 0x202020, 0x000080, 0xFFFFFF, 0xFFFF00, 0x00FF00, 0x5AC8FA, 0xFF9500]
    )
    func readable(hex: Int) {
        let accent = AppState.readableCustomAccent(hex)

        #expect(Self.contrast(accent, AppState.accentCardHex) >= 3)
        #expect(Self.contrast(0xFFFFFF, accent) >= 3)
    }

    @Test("A custom colour that reads already is kept", arguments: [0x007AFF, 0x5856D6, 0xAF52DE])
    func readableColourKept(hex: Int) {
        #expect(AppState.readableCustomAccent(hex) == hex)
    }

    @Test(
        "A colour's hex survives the trip through Color",
        arguments: TigerDuckTheme.coursePaletteHexes + AppState.themeColors.map { UInt32($0.hex) } + [0x5856D6]
    )
    func hexRoundTrip(hex: UInt32) {
        #expect(Color(hex: UInt(hex)).rgbHex == hex)
    }

    private static func contrast(_ first: Int, _ second: Int) -> Double {
        let (a, b) = (luminance(first), luminance(second))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private static func luminance(_ hex: Int) -> Double {
        let colour = Color(hex: UInt(hex)).resolve(in: EnvironmentValues())
        return 0.2126 * Double(colour.linearRed) + 0.7152 * Double(colour.linearGreen)
            + 0.0722 * Double(colour.linearBlue)
    }
}
