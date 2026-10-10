import Foundation
import UserNotifications

/// One-shot migration: purges the assignment reminders 2.0.x scheduled on the device, now that
/// the backend sends them.
///
/// The deleted `AssignmentReminderScheduler` queued up to 60 `UNUserNotificationCenter`
/// requests per user under the `"LA-reminder-"` prefix. Deleting the type cancels none of them:
/// they would still fire days or weeks later and duplicate the backend's reminders. The done
/// flag stops a rescan on every launch. Keep until the minimum supported version is past 2.1.0,
/// as a device can still arrive straight from 2.0.x with those requests queued.
enum PendingReminderPurgeMigration {
    /// Copy of the deleted `AssignmentReminderScheduler.requestPrefix`. That
    /// type is gone, so this migration owns its own copy rather than
    /// depending on a type that no longer exists.
    static let legacyReminderRequestPrefix = "LA-reminder-"

    private static let doneKey = "PendingReminderPurgeMigration.v1.done"

    static func runIfNeeded(
        center: PendingReminderPurgeCenter = UNUserNotificationCenter.current()
    ) async {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: doneKey) }
        await purgeLegacyReminders(center: center)
    }

    /// Same behaviour as the deleted scheduler's `cancelAllOwnedRequests()`:
    /// prefix-match the pending requests and remove only those.
    private static func purgeLegacyReminders(center: PendingReminderPurgeCenter) async {
        let pending = await center.pendingNotificationRequests()
        let ids = pending
            .map(\.identifier)
            .filter { $0.hasPrefix(legacyReminderRequestPrefix) }
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}

/// Narrow seam over `UNUserNotificationCenter` so the migration can be
/// pinned with a fake in tests instead of touching the real, process-global
/// notification centre. `UNUserNotificationCenter` already implements both
/// members with matching signatures, so the conformance below needs no
/// implementation of its own.
protocol PendingReminderPurgeCenter {
    func pendingNotificationRequests() async -> [UNNotificationRequest]
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: PendingReminderPurgeCenter {}
