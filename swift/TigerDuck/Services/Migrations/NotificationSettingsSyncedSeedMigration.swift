import Defaults
import Foundation

enum NotificationSettingsSyncedSeedMigration {
    private static let doneKey = "NotificationSettingsSyncedSeedMigration.v1.done"

    /// Earlier builds kept no synced copy of the notification settings. With no push pending, the
    /// device's values are that copy. A pending push holds an edit made on an earlier build, so it
    /// sends every field once, as those builds did. docs/decisions/0024-launch-before-first-unlock.md
    /// says why stored data must read back first.
    @MainActor
    static func runIfNeeded(
        current: NotificationSettingsSync.LocalPreferences,
        storedDataReadsBack: () -> Bool = { FirstUnlock.storedDataReadsBack() }
    ) {
        guard !UserDefaults.standard.bool(forKey: doneKey), storedDataReadsBack() else { return }
        if Defaults[.notificationSettingsPushPending] {
            Defaults[.notificationSettingsPushSendsEveryField] = true
        } else if NotificationSettingsSync.synced == nil {
            NotificationSettingsSync.synced = current
        }
        UserDefaults.standard.set(true, forKey: doneKey)
    }
}
