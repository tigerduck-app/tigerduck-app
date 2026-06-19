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
final class PushAppDelegate: NSObject, UIApplicationDelegate, PushTokenSource {
    /// Set by `TigerDuckApp` before the first token arrives. Called on the
    /// main thread with the raw token data.
    ///
    /// Lifetime contract: this delegate, the `TigerDuckApp`, and the shared
    /// `PushRegistrationService` all live for the entire app process. The
    /// closure does **not** weak-capture the registration service — there is
    /// no shorter lifetime to escape from, and a `[weak]` capture here would
    /// silently drop the token if scene-phase plumbing ever ran the closure
    /// before the strong reference had been established.
    ///
    /// `AppState.init` triggers `registerForRemoteNotifications()` before
    /// SwiftUI runs `.onAppear` — the appearance hook is what wires the
    /// forwarders, so APNs can race ahead and deliver the token while the
    /// closure is still nil. Any token/error that arrives in that gap is
    /// stashed in `bufferedToken`/`bufferedError` and replayed by the
    /// `didSet`s below when the closures are finally installed, so a
    /// launch token never gets dropped on the floor.
    var forwardToken: ((Data) -> Void)? {
        didSet {
            guard let forward = forwardToken, let token = bufferedToken else { return }
            bufferedToken = nil
            forward(token)
        }
    }
    /// Called when APNs registration fails (e.g. no entitlement, no network).
    /// Same app-lifetime contract as ``forwardToken``.
    var forwardError: ((Error) -> Void)? {
        didSet {
            guard let forward = forwardError, let error = bufferedError else { return }
            bufferedError = nil
            forward(error)
        }
    }

    private var bufferedToken: Data?
    private var bufferedError: Error?

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
        if let forward = forwardToken {
            forward(deviceToken)
        } else {
            // `.onAppear` hasn't wired the forwarder yet — hold the token
            // until it does so the launch registration isn't lost.
            bufferedToken = deviceToken
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        logger.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
        if let forward = forwardError {
            forward(error)
        } else {
            bufferedError = error
        }
    }

    var onSyncTrigger: (() async -> Void)?

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        if userInfo["kind"] as? String == "sync_trigger" {
            logger.info("Silent sync trigger received")
            Task {
                await onSyncTrigger?()
                completionHandler(.newData)
            }
        } else {
            completionHandler(.noData)
        }
    }
}
