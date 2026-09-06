#if os(macOS)
import AppKit
import UserNotifications
import os

/// macOS equivalent of `PushAppDelegate`. Captures APNs device tokens
/// via `NSApplicationDelegate` and forwards them to `PushCoordinator`
/// through the `PushTokenSource` protocol.
///
/// macOS does not have Live Activities (no PTS token) or background
/// fetch — the delegate only handles device-token registration and
/// silent sync-trigger pushes.
final class MacPushAppDelegate: NSObject, NSApplicationDelegate, PushTokenSource {
    var forwardToken: ((Data) -> Void)? {
        didSet {
            guard let forward = forwardToken, let token = bufferedToken else { return }
            bufferedToken = nil
            forward(token)
        }
    }
    var forwardError: ((Error) -> Void)? {
        didSet {
            guard let forward = forwardError, let error = bufferedError else { return }
            bufferedError = nil
            forward(error)
        }
    }
    var onSyncTrigger: (() async -> Void)?

    private var bufferedToken: Data?
    private var bufferedError: Error?

    var notificationDelegate: NotificationDelegate?

    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Push.MacDelegate")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let nd = NotificationDelegate()
        UNUserNotificationCenter.current().delegate = nd
        self.notificationDelegate = nd
    }

    func application(_ application: NSApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        logger.info("APNs registered (len=\(deviceToken.count, privacy: .public))")
        if let forward = forwardToken {
            forward(deviceToken)
        } else {
            bufferedToken = deviceToken
        }
    }

    func application(_ application: NSApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        logger.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
        if let forward = forwardError {
            forward(error)
        } else {
            bufferedError = error
        }
    }

    func application(_ application: NSApplication,
                     didReceiveRemoteNotification userInfo: [String: Any]) {
        if userInfo["kind"] as? String == "sync_trigger" {
            logger.info("Silent sync trigger received")
            Task { await onSyncTrigger?() }
        }
    }
}
#endif
