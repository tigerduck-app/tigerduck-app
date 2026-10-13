import Foundation

/// One-shot migration: gets each upgrading user's own reminder and Live Activity preferences
/// into the `notification` settings document. From 2.1.0 the backend sends reminders and reads
/// these from it, or uses its own defaults; before, they lived only on the device. Without this
/// an upgrader who never opens settings gets the server's offsets, and one who had switched
/// reminders off gets them again. It does not push: like every trigger it runs
/// `AppState.reconcileNotificationSettings`, which adopts sections the account has and writes
/// only missing ones. The done flag waits for that to settle, so a first launch offline, signed
/// out or with course sync off retries. Keep until the minimum supported version is past 2.1.0.
enum NotificationSettingsSeedMigration {
    private static let doneKey = "NotificationSettingsSeedMigration.v1.done"

    /// `reconcile` starts the routine and calls the closure it is handed
    /// once the document has settled.
    static func runIfNeeded(
        reconcile: (_ onSettled: @escaping @MainActor () -> Void) -> Void
    ) {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        reconcile {
            UserDefaults.standard.set(true, forKey: doneKey)
        }
    }
}
