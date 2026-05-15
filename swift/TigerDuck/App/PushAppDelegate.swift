import UIKit
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

    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Push.Delegate")

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationLock.shared.mask(for: window?.windowScene)
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
