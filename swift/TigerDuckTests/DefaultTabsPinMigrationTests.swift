// `DefaultTabsPinMigration` — which installs keep the pre-2.3.0 default bar
// (Home, Class table, Calendar) when the default became Home, Class table,
// Mail. iPhone/iPad-only like the migration; the test target also builds
// for macOS.
#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct DefaultTabsPinMigrationTests {
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
