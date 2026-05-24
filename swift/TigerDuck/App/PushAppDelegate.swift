import UIKit
import UserNotifications
import os

/// UIKit hook that captures the standard APNs device token.
///
/// SwiftUI's `@main App` doesn't expose `didRegisterForRemoteNotifications`
/// directly, so we bolt on a tiny `UIApplicationDelegate` via
/// `@UIApplicationDelegateAdaptor`. The single responsibility is to forward
/// the token to a `forwardTo` closure, which `TigerDuckApp` wires to the
/// shared `PushRegistrationService`.
final class PushAppDelegate: NSObject, UIApplicationDelegate {
    /// Set by `TigerDuckApp` before the first token arrives. Called on the
    /// main thread with the raw token data.
    ///
    /// Lifetime contract: this delegate, the `TigerDuckApp`, and the shared
    /// `PushRegistrationService` all live for the entire app process. The
    /// closure does **not** weak-capture the registration service — there is
    /// no shorter lifetime to escape from, and a `[weak]` capture here would
    /// silently drop the token if scene-phase plumbing ever ran the closure
    /// before the strong reference had been established.
    var forwardToken: ((Data) -> Void)?
    /// Called when APNs registration fails (e.g. no entitlement, no network).
    /// Same app-lifetime contract as ``forwardToken``.
    var forwardError: ((Error) -> Void)?

    /// Owns the `UNUserNotificationCenterDelegate` for the lifetime of the
    /// app. `UNUserNotificationCenter` retains the delegate weakly, so this
    /// strong reference is what keeps it alive — without it the singleton
    /// would silently drop taps the moment ARC reclaimed the local variable
    /// set in `didFinishLaunchingWithOptions`.
    var notificationDelegate: NotificationDelegate?

    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Push.Delegate")

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Install the notification delegate BEFORE any push can arrive so
        // a cold-launch tap (where iOS launches the app from a tapped
        // notification) is routed through `routeTap` instead of falling
        // back to the OS default open behaviour.
        let nd = NotificationDelegate()
        UNUserNotificationCenter.current().delegate = nd
        self.notificationDelegate = nd
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        logger.info("APNs registered (len=\(deviceToken.count, privacy: .public))")
        forwardToken?(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        logger.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
        forwardError?(error)
    }
}
