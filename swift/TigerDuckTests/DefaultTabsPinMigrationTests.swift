// Which installs `DefaultTabsPinMigration` keeps on the pre-2.3.0 bar (Home, Class table,
// Calendar) rather than Home, Class table, Mail. iPhone/iPad-only like the migration; the test
// target also builds for macOS. `doneKey` mirrors the migration's private flag literal.
#if os(iOS)
import Defaults
import Foundation
import Testing
@testable import TigerDuck

private let doneKey = "DefaultTabsPinMigration.v1.done"

@MainActor
struct DefaultTabsPinMigrationTests {
    private static func withRealMigrationKeys(_ body: () throws -> Void) async throws {
        try await withExclusiveRealDefaults {
            let names = [
                doneKey,
                Defaults.Keys.configuredTabsData.name,
                Defaults.Keys.lastShownWhatsNewVersion.name,
                Defaults.Keys.hasCompletedOnboarding.name,
            ]
            let saved = names.map { UserDefaults.standard.object(forKey: $0) }
            defer {
                for (name, value) in zip(names, saved) {
                    if let value {
                        UserDefaults.standard.set(value, forKey: name)
                    } else {
                        UserDefaults.standard.removeObject(forKey: name)
                    }
                }
            }
            names.forEach(UserDefaults.standard.removeObject(forKey:))
            // Not `hasCompletedOnboarding`: its registered default reads
            // back as `false`, which is what "absent" means for it.
            for name in names.prefix(3) {
                try #require(
                    UserDefaults.standard.object(forKey: name) == nil,
                    "\(name) is still set by a lower defaults domain on this device"
                )
            }
            try body()
        }
    }

    // MARK: - runIfNeeded

    @Test func anUpgradeStoresTheOldBarOnce() async throws {
        try await Self.withRealMigrationKeys {
            Defaults[.lastShownWhatsNewVersion] = "2.2.0"
            Defaults[.hasCompletedOnboarding] = true

            #expect(DefaultTabsPinMigration.runIfNeeded())
            #expect(AppState.decodeConfiguredTabs(Defaults[.configuredTabsData]) == [.home, .classTable, .calendar])
            #expect(UserDefaults.standard.bool(forKey: doneKey))

            // Once done, never again — even with the bar gone.
            Defaults[.configuredTabsData] = nil
            #expect(!DefaultTabsPinMigration.runIfNeeded())
            #expect(Defaults[.configuredTabsData] == nil)
        }
    }

    /// `AppState.init` seeds the running version before migrations run.
    @Test func aFreshInstallStoresNothing() async throws {
        try await Self.withRealMigrationKeys {
            Defaults[.lastShownWhatsNewVersion] = "2.3.0"

            #expect(!DefaultTabsPinMigration.runIfNeeded())
            #expect(Defaults[.configuredTabsData] == nil)
            #expect(UserDefaults.standard.bool(forKey: doneKey))
        }
    }

    @Test func anUpgradesCustomizedBarIsNotOverwritten() async throws {
        try await Self.withRealMigrationKeys {
            Defaults[.lastShownWhatsNewVersion] = "2.2.0"
            Defaults[.hasCompletedOnboarding] = true
            let mine = try JSONEncoder().encode(["home", "gpa"])
            Defaults[.configuredTabsData] = mine

            #expect(!DefaultTabsPinMigration.runIfNeeded())
            #expect(Defaults[.configuredTabsData] == mine)
        }
    }

    // MARK: - Classification
    @Test func anExistingUntouchedBarKeepsCalendar() {
        #expect(DefaultTabsPinMigration.keepsPreviousDefault(storedTabs: nil, isExistingInstall: true))
    }

    @Test func aCustomizedBarIsLeftAlone() throws {
        let stored = try JSONEncoder().encode(["home", "gpa"])
        #expect(!DefaultTabsPinMigration.keepsPreviousDefault(storedTabs: stored, isExistingInstall: true))
    }

    /// A stored list that decodes to nothing shows the default, so it
    /// counts as untouched.
    @Test func aStoredBarThatDecodesToNothingKeepsCalendar() throws {
        let empty = try JSONEncoder().encode([String]())
        #expect(DefaultTabsPinMigration.keepsPreviousDefault(storedTabs: empty, isExistingInstall: true))
        #expect(DefaultTabsPinMigration.keepsPreviousDefault(storedTabs: Data("junk".utf8), isExistingInstall: true))
    }

    @Test func aFreshInstallGetsTheNewDefault() {
        #expect(!DefaultTabsPinMigration.keepsPreviousDefault(storedTabs: nil, isExistingInstall: false))
    }

    @Test func anUpgradeFromBefore230IsAnExistingInstall() {
        #expect(DefaultTabsPinMigration.isUpgradeFromBeforeNewDefault(lastShownWhatsNewVersion: "2.2.0", hasCompletedOnboarding: true))
        #expect(DefaultTabsPinMigration.isUpgradeFromBeforeNewDefault(lastShownWhatsNewVersion: "2.1.4", hasCompletedOnboarding: false))
    }

    /// `AppState.init` seeds the running version on a fresh install, and on
    /// the first launch after a full reset, before the migration runs.
    @Test func aFreshInstallOrAResetIsNot() {
        #expect(!DefaultTabsPinMigration.isUpgradeFromBeforeNewDefault(lastShownWhatsNewVersion: "2.3.0", hasCompletedOnboarding: true))
        #expect(!DefaultTabsPinMigration.isUpgradeFromBeforeNewDefault(lastShownWhatsNewVersion: "2.4.0", hasCompletedOnboarding: false))
    }

    /// A build from before the What's New marker leaves it empty.
    @Test func withNoMarkerOnboardingDecides() {
        #expect(DefaultTabsPinMigration.isUpgradeFromBeforeNewDefault(lastShownWhatsNewVersion: nil, hasCompletedOnboarding: true))
        #expect(!DefaultTabsPinMigration.isUpgradeFromBeforeNewDefault(lastShownWhatsNewVersion: nil, hasCompletedOnboarding: false))
    }

    @Test func theKeptBarIsTheOldDefaultAndDecodes() throws {
        let data = try JSONEncoder().encode(DefaultTabsPinMigration.previousDefaultTabs)
        #expect(AppState.decodeConfiguredTabs(data) == [.home, .classTable, .calendar])
    }
}
#endif
