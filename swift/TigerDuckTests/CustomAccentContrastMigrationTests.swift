import Defaults
import Foundation
import Testing
@testable import TigerDuck

private let doneKey = "CustomAccentContrastMigration.v1.done"

@Suite(.serialized)
@MainActor
struct CustomAccentContrastMigrationTests {
    private static func withSavedAccent(_ hex: Int, _ body: () -> Void) async {
        await withExclusiveRealDefaults {
            let (accent, done) = (Defaults[.accentColorHex], UserDefaults.standard.object(forKey: doneKey))
            defer {
                Defaults[.accentColorHex] = accent
                if let done { UserDefaults.standard.set(done, forKey: doneKey) } else { UserDefaults.standard.removeObject(forKey: doneKey) }
            }
            UserDefaults.standard.removeObject(forKey: doneKey)
            Defaults[.accentColorHex] = hex
            body()
        }
    }

    @Test func aCustomAccentTooLightForTheLightCardsMovesToItsReadableShade() async {
        await Self.withSavedAccent(0x949494) {
            #expect(CustomAccentContrastMigration.runIfNeeded())

            #expect(Defaults[.accentColorHex] == AccentContrast.readable(0x949494))
            #expect(Defaults[.accentColorHex] != 0x949494)
        }
    }

    @Test(arguments: AppState.themeColors.map(\.hex) + [0x5856D6])
    func aPresetOrAReadableCustomAccentStays(hex: Int) async {
        await Self.withSavedAccent(hex) {
            #expect(!CustomAccentContrastMigration.runIfNeeded())

            #expect(Defaults[.accentColorHex] == hex)
        }
    }

    @Test func itRunsOnce() async {
        await Self.withSavedAccent(0x949494) {
            CustomAccentContrastMigration.runIfNeeded()
            Defaults[.accentColorHex] = 0x949494

            #expect(!CustomAccentContrastMigration.runIfNeeded())
            #expect(Defaults[.accentColorHex] == 0x949494)
        }
    }
}
