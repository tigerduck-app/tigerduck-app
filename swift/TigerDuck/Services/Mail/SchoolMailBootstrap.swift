#if os(iOS)
import Foundation

@MainActor
enum SchoolMailBootstrap {
    static func install(
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
            notificationsDenied: MailNotificationPermission.lastKnownDenied
        ) else { return }
        MailBackgroundRefresh.schedule()
    }
}
#endif
