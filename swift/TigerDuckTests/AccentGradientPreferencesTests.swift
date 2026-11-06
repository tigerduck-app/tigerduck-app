import Foundation
import Testing
import TigerDuckCore
@testable import TigerDuck

@Suite(.serialized)
@MainActor
struct AccentGradientPreferencesTests {
    private static let keys = ["accentColorHex", "accentGradient", "accentGradientOnDevices"]
    private static let gradient = AccentGradient(stops: [0x4B48D1, 0x9442C7, 0xD61F45], style: .angular)!

    private static func withSavedAccent(_ body: () throws -> Void) async rethrows {
        try await withExclusiveRealDefaults {
            let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
            defer {
                for (key, value) in zip(keys, saved) {
                    if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
                }
            }
            keys.forEach(UserDefaults.standard.removeObject(forKey:))
            try body()
        }
    }

    @Test("The custom colour the previous release saved is a one-stop accent, unchanged")
    func theReleasedCustomColourComesThrough() async {
        await Self.withSavedAccent {
            UserDefaults.standard.set(0x5856D6, forKey: "accentColorHex")

            let preferences = AppPreferences()

            #expect(preferences.accent == AccentGradient(color: 0x5856D6))
            #expect(preferences.accentColorHex == 0x5856D6)
            #expect(UserDefaults.standard.integer(forKey: "accentColorHex") == 0x5856D6)
        }
    }

    @Test("A saved gradient reads back, its first stop saved as the one colour older builds read")
    func aGradientIsSavedBesideItsFirstStop() async {
        await Self.withSavedAccent {
            AppPreferences().accent = Self.gradient

            #expect(UserDefaults.standard.integer(forKey: "accentColorHex") == 0x4B48D1)
            #expect(AppPreferences().accent == Self.gradient)
        }
    }

    @Test("A colour picked in a build without gradients replaces the gradient")
    func anOlderBuildsPickCancelsTheGradient() async {
        await Self.withSavedAccent {
            AppPreferences().accent = Self.gradient
            UserDefaults.standard.set(0x34C759, forKey: "accentColorHex")

            #expect(AppPreferences().accent == AccentGradient(color: 0x34C759))
        }
    }

    @Test("A preset chosen replaces the gradient, one that starts with the preset too")
    func aPresetReplacesTheGradient() async {
        await Self.withSavedAccent {
            let preferences = AppPreferences()
            preferences.accent = AccentGradient(stops: [0x007AFF, 0xAF52DE])!
            preferences.accent = AccentGradient(color: 0x007AFF)

            #expect(!preferences.accent.isGradient)
            #expect(UserDefaults.standard.object(forKey: "accentGradient") == nil)
            #expect(!AppPreferences().accent.isGradient)
        }
    }

    @Test("Widgets, the Watch and Live Activities get one colour unless the switch is on")
    func devicesGetTheGradientOnlyWhenSwitchedOn() async {
        await Self.withSavedAccent {
            let preferences = AppPreferences()
            preferences.accent = Self.gradient
            #expect(!preferences.accentGradientOnDevices)
            #expect(preferences.deviceAccentGradient == nil)

            preferences.accentGradientOnDevices = true
            #expect(preferences.deviceAccentGradient == Self.gradient)
            #expect(AppPreferences().deviceAccentGradient == Self.gradient)

            preferences.accent = AccentGradient(color: 0x5856D6)
            #expect(preferences.deviceAccentGradient == nil)
            #expect(preferences.accentColorHex == 0x5856D6)
        }
    }
}
