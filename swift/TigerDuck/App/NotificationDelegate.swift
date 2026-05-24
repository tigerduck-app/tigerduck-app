import Foundation
import UserNotifications
import os

/// Routes incoming `UNNotificationResponse`s to whatever state the rest
/// of the app subscribes to. The wiring is split so this delegate has no
/// dependency on AppState — `TigerDuckApp` hands it closures at launch.
///
/// Lifetime: `UNUserNotificationCenter` holds its delegate weakly, so
/// `PushAppDelegate` keeps the strong reference. The delegate itself
/// lives for the whole app process.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    /// Invoked when the user taps a notification (either from the lock
    /// screen / banner or from Notification Center).
    var routeTap: ((UNNotificationResponse) -> Void)?

    /// Decide whether to show a banner / play a sound when a push arrives
    /// while the app is in the foreground. Defaults to banner+sound+list.
    var allowForegroundPresentation: ((UNNotification) -> UNNotificationPresentationOptions)?

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
        routeTap?(response)
        completionHandler()
    }
}
