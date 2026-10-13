import Defaults
import Foundation
import Testing
@testable import TigerDuck

/// A newer build can save or send a preset this one does not know, and a downgrade reads back
/// whatever the newer build stored.
struct VisualPresetTests {
    @Test("A preset this build does not know decodes as TigerDuck, and its neighbours keep theirs")
    func unknownPresetDecodesAsTigerDuck() throws {
        let json = Data(#"["iosInspired", "someFuturePreset", "default"]"#.utf8)

        let presets = try JSONDecoder().decode([VisualPreset].self, from: json)

        #expect(presets == [.iosInspired, .default, .default])
    }

    @Test("A stored preset this build does not know reads as TigerDuck")
    func unknownStoredPresetReadsAsTigerDuck() throws {
        let suiteName = "VisualPresetTests-\(UUID().uuidString)"
        let suite = try #require(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let key = Defaults.Key<VisualPreset>(
            AppConstants.UserDefaultsKeys.visualPreset, default: .default, suite: suite
        )
        suite.set("someFuturePreset", forKey: key.name)

        #expect(Defaults[key] == .default)
    }
}
