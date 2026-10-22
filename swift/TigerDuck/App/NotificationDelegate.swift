import Foundation
import UserNotifications
import os

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    var routeTap: ((UNNotificationResponse) -> Void)? {
        didSet {
            guard routeTap != nil, !pendingResponses.isEmpty else { return }
            let drained = pendingResponses
            pendingResponses.removeAll()
            for r in drained { routeTap?(r) }
        }
    }

    var allowForegroundPresentation: ((UNNotification) -> UNNotificationPresentationOptions)?

    private var pendingResponses: [UNNotificationResponse] = []

    private let logger = Logger(
        subsystem: "org.ntust.app.TigerDuck",
        category: "Push.Delegate"
    )

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let opts = allowForegroundPresentation?(notification) ?? [.banner, .sound, .list]
        completionHandler(opts)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let routeTap {
            routeTap(response)
        } else {
            pendingResponses = [response]
        }
        completionHandler()
    }
}
