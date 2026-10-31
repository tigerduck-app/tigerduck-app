import Foundation
import UserNotifications

enum PendingReminderPurgeMigration {
    static let legacyReminderRequestPrefix = "LA-reminder-"

    private static let doneKey = "PendingReminderPurgeMigration.v1.done"

    static func runIfNeeded(
        center: PendingReminderPurgeCenter = UNUserNotificationCenter.current()
    ) async {
        guard !AppUserDefaults.standard.bool(forKey: doneKey) else { return }
        defer { AppUserDefaults.standard.set(true, forKey: doneKey) }
        await purgeLegacyReminders(center: center)
    }

    private static func purgeLegacyReminders(center: PendingReminderPurgeCenter) async {
        let pending = await center.pendingNotificationRequests()
        let ids = pending
            .map(\.identifier)
            .filter { $0.hasPrefix(legacyReminderRequestPrefix) }
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}

protocol PendingReminderPurgeCenter {
    func pendingNotificationRequests() async -> [UNNotificationRequest]
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: PendingReminderPurgeCenter {}
