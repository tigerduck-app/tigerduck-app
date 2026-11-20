#if os(iOS)
import Foundation

@MainActor
enum SchoolMailBootstrap {
    static func install(
        account: MailAccountManager? = nil,
        notifier: MailNotifier = MailChecker.shared.notifier
    ) {
        // Swift 5 mode type-checks a default argument outside the main actor (SE-0411 is off).
        let account = account ?? .shared
        guard SchoolMailAvailability.isEnabled else { return }
        SchoolMailCharsetHook.install()
        Task { _ = await MailNotificationPermission.isDenied() }
        account.resumeInterruptedCacheWipe()
        account.listeners.signedIn = {
            MailBackgroundRefresh.schedule()
            Task { await MailNotificationPermission.requestIfNeeded() }
        }
        account.listeners.signedOut = {
            MailBackgroundRefresh.cancel()
            Task { await notifier.removeAll() }
        }
        account.listeners.authFailed = {
            MailBackgroundRefresh.cancel()
            Task { await notifier.notifyAuthFailure() }
        }
        account.listeners.notificationsEnabled = {
            MailBackgroundRefresh.schedule()
            Task { await MailNotificationPermission.requestIfNeeded() }
        }
        account.listeners.notificationsDisabled = {
            MailBackgroundRefresh.cancel()
            Task { await notifier.removeAll() }
        }
    }

    static func sceneDidBecomeActive() {
        guard SchoolMailAvailability.isEnabled else { return }
        Task { _ = await MailNotificationPermission.isDenied() }
        Task { await MailForegroundCheck.runIfDue() }
    }

    /// iOS expects the next refresh to be requested as the app leaves the foreground, and can
    /// suspend it before an `await` returns, so this decides at once from the last permission read.
    static func sceneDidEnterBackground() {
        let account = MailAccountManager.shared
        guard MailBackgroundRefresh.shouldRescheduleAfterHandling(
            featureEnabled: SchoolMailAvailability.isEnabled,
            signedIn: account.isLoggedIn,
            notificationsEnabled: account.notificationsEnabled,
            authFailed: account.authFailed,
            notificationsDenied: MailNotificationPermission.lastKnownDenied
        ) else { return }
        MailBackgroundRefresh.schedule()
    }
}
#endif
