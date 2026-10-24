import SwiftUI
import Testing
@testable import TigerDuck

@MainActor
struct CustomAccentTests {
    @Test(
        "The cards a custom accent is checked on are the card surface over the page",
        arguments: [(ColorScheme.dark, AccentContrast.cardHex), (.light, AccentContrast.lightCardHex)]
    )
    func cardMatchesTheTheme(scheme: ColorScheme, hex: Int) {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        let surface = Color.cardSurface.resolve(in: environment)
        let page = Color.backgroundPrimary.resolve(in: environment)
        let card = Color(Color.Resolved(
            red: surface.red * surface.opacity + page.red * (1 - surface.opacity),
            green: surface.green * surface.opacity + page.green * (1 - surface.opacity),
            blue: surface.blue * surface.opacity + page.blue * (1 - surface.opacity)
        ))

        #expect(card.rgbHex == UInt32(hex))
    }

    @Test(
        "A custom accent reads on the dark and the light cards and under white marks",
        arguments: [0x000000, 0x202020, 0x000080, 0xFFFFFF, 0xFFFF00, 0x00FF00, 0x5AC8FA, 0xFF9500, 0x939393]
    )
    func readable(hex: Int) {
        let accent = AccentContrast.readable(hex)

        #expect(Self.contrast(accent, AccentContrast.cardHex) >= 3)
        #expect(Self.contrast(accent, AccentContrast.lightCardHex) >= 3)
        #expect(Self.contrast(0xFFFFFF, accent) >= 3)
    }

    @Test("A custom colour that reads already is kept", arguments: [0x007AFF, 0x5856D6, 0xAF52DE])
    func readableColourKept(hex: Int) {
        #expect(AccentContrast.readable(hex) == hex)
    }

    @Test(
        "A colour's hex survives the trip through Color",
        arguments: TigerDuckTheme.coursePaletteHexes + AppState.themeColors.map { UInt32($0.hex) } + [0x5856D6]
    )
    func hexRoundTrip(hex: UInt32) {
        #expect(Color(hex: UInt(hex)).rgbHex == hex)
    }

    @Test("Opening the picker on the saved accent saves nothing")
    func openingSavesNothing() {
        let preview = AccentPreview()

        #expect(preview.preview(0x007AFF, saved: 0x007AFF) == nil)
        #expect(preview.hex == nil)
    }

    @Test("A pick is drawn readable and saved as drawn")
    func pickIsSavedReadable() throws {
        let preview = AccentPreview()

        let saved = preview.preview(0xFFFFFF, saved: 0x007AFF)

        #expect(saved == AccentContrast.readable(0xFFFFFF))
        #expect(preview.shownHex(saved: 0x007AFF) == saved)
        #expect(preview.isCustom(saved: 0x007AFF))
        #expect(preview.takeForSaving(try #require(saved)))
        #expect(preview.hex == nil)
    }

    @Test("A preset chosen before the save keeps the save from replacing it")
    func presetBeatsPendingSave() throws {
        let preview = AccentPreview()
        let pending = try #require(preview.preview(0xFFFFFF, saved: 0x007AFF))

        preview.clear()

        #expect(!preview.takeForSaving(pending))
        #expect(!preview.isCustom(saved: 0x007AFF))
    }

    @Test("Only the latest pick is saved")
    func latestPickWins() throws {
        let preview = AccentPreview()
        let older = try #require(preview.preview(0x5856D6, saved: 0x007AFF))
        let newer = try #require(preview.preview(0x8E44AD, saved: 0x007AFF))

        #expect(!preview.takeForSaving(older))
        #expect(preview.takeForSaving(newer))
    }

    @Test("Dragging back to the saved accent drops the preview")
    func backToSavedDropsPreview() {
        let preview = AccentPreview()
        _ = preview.preview(0x5856D6, saved: 0x007AFF)

        #expect(preview.preview(0x007AFF, saved: 0x007AFF) == nil)
        #expect(preview.hex == nil)
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
