import Defaults
import Foundation

enum DefaultTabsPinMigration {
    static let previousDefaultTabs = ["home", "classTable", "calendar"]

    private static let doneKey = "DefaultTabsPinMigration.v1.done"

    @discardableResult
    static func runIfNeeded() -> Bool {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return false }
        defer { UserDefaults.standard.set(true, forKey: doneKey) }
        let isExistingInstall = isUpgradeFromBeforeNewDefault(
            lastShownWhatsNewVersion: Defaults[.lastShownWhatsNewVersion],
            hasCompletedOnboarding: Defaults[.hasCompletedOnboarding]
        )
        guard keepsPreviousDefault(storedTabs: Defaults[.configuredTabsData], isExistingInstall: isExistingInstall),
              let data = try? JSONEncoder().encode(previousDefaultTabs) else { return false }
        Defaults[.configuredTabsData] = data
        return true
    }

    static func isUpgradeFromBeforeNewDefault(lastShownWhatsNewVersion: String?, hasCompletedOnboarding: Bool) -> Bool {
        guard let marker = lastShownWhatsNewVersion, let lastOpened = AppVersion(marker) else {
            return hasCompletedOnboarding
        }
        guard let changed = AppVersion("2.3.0") else { return false }
        return lastOpened < changed
    }

    static func keepsPreviousDefault(storedTabs: Data?, isExistingInstall: Bool) -> Bool {
        isExistingInstall && AppState.decodeConfiguredTabs(storedTabs) == nil
    }
}
