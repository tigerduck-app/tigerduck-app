import Defaults
import Foundation

/// One-shot migration: keeps the bottom bar of an existing user who never
/// customized it, now that the default bar has changed.
///
/// Context: an untouched bar is never stored — `configuredTabs` falls back
/// to `AppFeature.defaultTabs` on every launch. 2.3.0 changed that default
/// from Home, Class table, Calendar to Home, Class table, Mail, so without
/// this an existing user's Calendar tab would silently turn into Mail.
/// Instead the old default is stored as their own bar, and 2.3.0's What's
/// New asks whether to swap Calendar for Mail. A fresh install has
/// nothing to keep and starts on the new default.
///
/// Keep while a device can still arrive here from a build before 2.3.0.
enum DefaultTabsPinMigration {
    /// The default bar before 2.3.0, as stored raw values. A copy, so this
    /// file doesn't depend on what `AppFeature.defaultTabs` later becomes.
    static let previousDefaultTabs = ["home", "classTable", "calendar"]

    private static let doneKey = "DefaultTabsPinMigration.v1.done"

    /// Returns whether it stored the old default, so the caller can reload
    /// the bar it already read.
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

    /// Whether this launch is an upgrade from a version with the old default.
    /// `lastShownWhatsNewVersion` holds the last version opened, so one
    /// before 2.3.0 says so. A fresh install — including the first launch
    /// after Settings' full reset, which wipes everything — has the running
    /// version seeded into it by `AppState.init` before migrations run, so
    /// it never counts. A build from before the marker existed leaves it
    /// empty; finished onboarding vouches for those.
    static func isUpgradeFromBeforeNewDefault(lastShownWhatsNewVersion: String?, hasCompletedOnboarding: Bool) -> Bool {
        guard let marker = lastShownWhatsNewVersion, let lastOpened = AppVersion(marker) else {
            return hasCompletedOnboarding
        }
        guard let changed = AppVersion("2.3.0") else { return false }
        return lastOpened < changed
    }

    /// Only an install that predates this build has a bar to keep, and only
    /// an untouched one — a stored bar is the user's own and stays as it is.
    /// "Untouched" is what `configuredTabs` reads as the default: nothing
    /// stored, or something that decodes to no tabs. Runs on a fresh
    /// install's first launch too, before onboarding is completed.
    static func keepsPreviousDefault(storedTabs: Data?, isExistingInstall: Bool) -> Bool {
        isExistingInstall && AppState.decodeConfiguredTabs(storedTabs) == nil
    }
}
