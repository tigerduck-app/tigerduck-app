import Defaults
import Foundation
import Testing
@testable import TigerDuck

private let doneKey = "RemovedLanguageResetMigration.v1.done"

@Suite(.serialized)
@MainActor
struct RemovedLanguageResetMigrationTests {
    private static let languageKey = Defaults.Key<String>.appLanguage

    private static func withSavedLanguage(_ tag: String, _ body: () -> Void) async {
        await withExclusiveRealDefaults {
            let stores = [(UserDefaults.standard, doneKey), (languageKey.suite, languageKey.name)]
            let saved = stores.map { store, key in (store, key, Self.storedValue(store, key)) }
            defer {
                for (store, key, value) in saved {
                    if let value { store.set(value, forKey: key) } else { store.removeObject(forKey: key) }
                }
            }
            UserDefaults.standard.removeObject(forKey: doneKey)
            Defaults[.appLanguage] = tag
            body()
        }
    }

    /// What a key holds in its suite's own domain. `object(forKey:)` would also return the default
    /// `Defaults` registers for the language, which the restore would then write as a stored value.
    private static func storedValue(_ store: UserDefaults, _ key: String) -> Any? {
        guard let domain = Bundle.main.bundleIdentifier else { return nil }
        return store.persistentDomain(forName: domain)?[key]
    }

    @Test(arguments: ["ar", "ar-SA", "fa", "fa_IR", "he", "he-IL", "ur", "ur-PK"])
    func aRemovedLanguageMovesToTheSystemSetting(tag: String) async {
        await Self.withSavedLanguage(tag) {
            #expect(RemovedLanguageResetMigration.runIfNeeded())

            #expect(Defaults[.appLanguage] == LanguageManager.system)
        }
    }

    @Test(arguments: [LanguageManager.system, "en", "en-GB", "zh-Hant", "ja", "fil", "ru"])
    func aLanguageTheAppStillHasStays(tag: String) async {
        await Self.withSavedLanguage(tag) {
            #expect(!RemovedLanguageResetMigration.runIfNeeded())

            #expect(Defaults[.appLanguage] == tag)
        }
    }

    @Test func itRunsOnce() async {
        await Self.withSavedLanguage("ar") {
            RemovedLanguageResetMigration.runIfNeeded()
            Defaults[.appLanguage] = "ar"

            #expect(!RemovedLanguageResetMigration.runIfNeeded())
            #expect(Defaults[.appLanguage] == "ar")
        }
    }
}
