import Foundation
#if os(iOS)
import UserNotifications

@MainActor
protocol DeliveredNotificationCenter {
    func deliveredNotificationDetails() async -> [(identifier: String, thread: String, userInfo: [AnyHashable: Any])]
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

extension DeliveredNotificationCenter {
    /// iOS keeps a delivered notification until it is removed and has no expiry time for one.
    func removeExpiredReminders(now: Date = AppClock.now()) async {
        let expired = await deliveredNotificationDetails()
            .filter { DeepLink.reminderDue(from: $0.userInfo).map { $0 <= now } ?? false }
            .map(\.identifier)
        removeDeliveredNotifications(withIdentifiers: expired)
    }
}

extension UNUserNotificationCenter: DeliveredNotificationCenter {
    func deliveredNotificationDetails() async -> [(identifier: String, thread: String, userInfo: [AnyHashable: Any])] {
        await deliveredNotifications().map {
            ($0.request.identifier, $0.request.content.threadIdentifier, $0.request.content.userInfo)
        }
    }
}
#endif
