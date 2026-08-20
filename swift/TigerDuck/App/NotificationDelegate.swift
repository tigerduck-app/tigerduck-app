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
    /// screen / banner or from Notification Center). Assignment drains
    /// any responses buffered while the closure was still nil — covers
    /// the cold-launch case where iOS delivers `didReceive` before
    /// SwiftUI's `.onAppear` runs to wire this closure.
    var routeTap: ((UNNotificationResponse) -> Void)? {
        didSet {
            guard routeTap != nil, !pendingResponses.isEmpty else { return }
            let drained = pendingResponses
            pendingResponses.removeAll()
            for r in drained { routeTap?(r) }
        }
    }

    /// Decide whether to show a banner / play a sound when a push arrives
    /// while the app is in the foreground. Defaults to banner+sound+list.
    var allowForegroundPresentation: ((UNNotification) -> UNNotificationPresentationOptions)?

    /// Buffer for responses delivered before `routeTap` is wired. UN
    /// dispatches its delegate callbacks on main and SwiftUI bodies/
    /// onAppear also run on main, so this array is only ever touched
    /// from the main thread — no extra synchronization needed.
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
            // Cold-launch path: SwiftUI hasn't run onAppear yet, so the
            // routing closure isn't installed. Hold the response until
            // it is, then drain via `routeTap.didSet`.
            pendingResponses.append(response)
        }
        completionHandler()
    }
}
