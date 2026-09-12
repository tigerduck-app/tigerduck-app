import Foundation
import UserNotifications

/// One-shot migration: purges any locally-scheduled assignment reminder
/// notifications left behind after reminders moved server-side.
///
/// Context: the deleted `AssignmentReminderScheduler`
/// (`LiveActivity/Scheduling/AssignmentReminderScheduler.swift`) used to
/// schedule up to 60 pending `UNUserNotificationCenter` requests per user,
/// identified by the `"LA-reminder-"` prefix. Removing that type does not
/// cancel requests it already scheduled — they keep sitting in the
/// notification centre and will fire on their original due-date-relative
/// schedule days or weeks later, duplicating the reminders the backend now
/// sends. This migration removes them once, on the upgrade that drops local
/// scheduling, and flags itself done so it never re-scans on every launch.
///
/// Keep until the minimum supported version is past 2.1.0: until then a
/// device can still arrive here straight from 2.0.x with those requests
/// queued.
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
