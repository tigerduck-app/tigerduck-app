import Defaults
import Foundation

enum NotificationSettingsSyncedSeedMigration {
    private static let doneKey = "NotificationSettingsSyncedSeedMigration.v1.done"

    /// Starts the synced copy a push diffs against from the device's values. A push left pending
    /// holds an edit not yet on the server; diffed against a copy of itself it would send nothing and
    /// the next reconcile would revert it, so that push sends every field instead. Signed out, the
    /// next sign-in starts the copy. docs/decisions/0002-notification-settings-json-merge.md has the
    /// design; docs/decisions/0024-launch-before-first-unlock.md says why stored data must read back first.
    @MainActor
    static func runIfNeeded(
        current: @autoclosure () -> NotificationSettingsSync.LocalPreferences,
        signedIn: @autoclosure () -> Bool,
        storedDataReadsBack: () -> Bool = { FirstUnlock.storedDataReadsBack() }
    ) {
        guard !AppUserDefaults.standard.bool(forKey: doneKey), storedDataReadsBack() else { return }
        defer { AppUserDefaults.standard.set(true, forKey: doneKey) }
        guard signedIn() else { return }
        if Defaults[.notificationSettingsPushPending] {
            Defaults[.notificationSettingsPushSendsEveryField] = true
        } else if NotificationSettingsSync.synced == nil {
            NotificationSettingsSync.synced = current()
        }
    }
}
