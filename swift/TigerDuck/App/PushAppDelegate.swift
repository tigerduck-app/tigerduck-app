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
    var forwardToken: ((Data) -> Void)?
    /// Called when APNs registration fails (e.g. no entitlement, no network).
    var forwardError: ((Error) -> Void)?

    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Push.Delegate")

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
