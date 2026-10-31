import Defaults
import Foundation

enum NotificationSettingsSyncedSeedMigration {
    private static let doneKey = "NotificationSettingsSyncedSeedMigration.v1.done"

    /// Earlier builds kept no synced copy of the notification settings. With no push pending, the
    /// device's values are that copy, so an edit made before the first sync still goes up.
    @MainActor
    static func runIfNeeded(current: NotificationSettingsSync.LocalPreferences) {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        UserDefaults.standard.set(true, forKey: doneKey)
        guard !Defaults[.notificationSettingsPushPending], NotificationSettingsSync.synced == nil else { return }
        NotificationSettingsSync.synced = current
    }
}
