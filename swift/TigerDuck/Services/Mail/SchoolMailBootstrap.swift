#if os(iOS)
import Foundation

@MainActor
enum SchoolMailBootstrap {
    static func install(
    /// `account` and `notifier` are parameters so a test can install the hooks on its own
    /// instances and run them. Asserting that the singleton's five closures are non-nil passes
    /// with every hook body empty, and touches the app's real `UserDefaults` and cache directory.
    ///
    /// `account` defaults to `nil`, not `.shared`: a default argument is type-checked in a
    /// nonisolated context, and naming the main-actor `MailAccountManager.shared` there is an
    /// isolation error in Swift 6 mode. This `@MainActor` body resolves it instead, so a passed
    /// instance is used and every other caller still gets the singleton.
        account: MailAccountManager? = nil,
        notifier: MailNotifier = MailChecker.shared.notifier
    ) {
        let account = account ?? .shared
        guard SchoolMailAvailability.isEnabled else { return }
        SchoolMailCharsetHook.install()
        Task { _ = await MailNotificationPermission.isDenied() }
        account.resumeInterruptedCacheWipe()
        account.onSignedIn = {
            MailBackgroundRefresh.schedule()
            Task { await MailNotificationPermission.requestIfNeeded() }
        }
        account.onSignedOut = {
            MailBackgroundRefresh.cancel()
            Task { await notifier.removeAll() }
        }
        account.onAuthFailed = {
            MailBackgroundRefresh.cancel()
            Task { await notifier.notifyAuthFailure() }
        }
        account.onNotificationsEnabled = {
            MailBackgroundRefresh.schedule()
            Task { await MailNotificationPermission.requestIfNeeded() }
        }
        account.onNotificationsDisabled = {
            MailBackgroundRefresh.cancel()
            Task { await notifier.removeAll() }
        }
    }

    static func sceneDidBecomeActive() {
        guard SchoolMailAvailability.isEnabled else { return }
        Task { _ = await MailNotificationPermission.isDenied() }
        Task { await MailForegroundCheck.runIfDue() }
    }

    static func sceneDidEnterBackground() {
        let account = MailAccountManager.shared
        guard MailBackgroundRefresh.shouldRescheduleAfterHandling(
            featureEnabled: SchoolMailAvailability.isEnabled,
            signedIn: account.isLoggedIn,
            notificationsEnabled: account.notificationsEnabled,
            authFailed: account.authFailed,
    /// iOS expects the next refresh to be requested as the app leaves the foreground, and can
    /// suspend it before an `await` returns, so this decides at once from the last permission read.
            notificationsDenied: MailNotificationPermission.lastKnownDenied
        ) else { return }
        MailBackgroundRefresh.schedule()
    }
}
#endif
