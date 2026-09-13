import Foundation

/// One-shot migration: gets every upgrading user's own reminder and Live
/// Activity preferences into the `notification` settings document.
///
/// Before 2.1.0 these preferences lived only on the device — iOS never
/// wrote this document — and reminders were scheduled locally. From 2.1.0
/// the backend sends them and reads the preferences from the document,
/// falling back to its own defaults when there is none. Without this, an
/// upgrader who never opens a settings screen gets the server's defaults
/// instead of their own offsets, and one who had switched reminders off
/// starts receiving them again.
///
/// It does not push. It runs the same read-before-write routine as every
/// other trigger (`AppState.reconcileNotificationSettings`): a section the
/// account already has — from another device — is adopted, and only a
/// missing one is written from this device's values. The done flag is set
/// only once that routine reports the document settled, so an upgrade
/// whose first launch is offline, signed out or has course sync off tries
/// again on the next one.
///
/// Keep until the minimum supported version is past 2.1.0.
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
