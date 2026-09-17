#if os(iOS)
import Foundation

/// Launch-time wiring for School Mail, called from `TigerDuckApp`.
@MainActor
enum SchoolMailBootstrap {
    static func install() {
        guard SchoolMailAvailability.isEnabled else { return }
        SchoolMailCharsetHook.install()
        let account = MailAccountManager.shared
        let notifier = MailChecker.shared.notifier
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
        Task { await MailForegroundCheck.runIfDue() }
    }

    /// iOS expects the next refresh to be requested as the app leaves the foreground.
    static func sceneDidEnterBackground() {
        let account = MailAccountManager.shared
        guard SchoolMailAvailability.isEnabled, account.isLoggedIn,
              account.notificationsEnabled, !account.authFailed else { return }
        MailBackgroundRefresh.schedule()
    }
}
#endif
