#if os(iOS)
import Foundation

/// Launch-time wiring for School Mail, called from `TigerDuckApp`.
@MainActor
enum SchoolMailBootstrap {
    /// `account` and `notifier` are parameters purely so a test can install the hooks onto its
    /// own instances and then *run* them, instead of asserting that five closures are non-nil
    /// on the production singleton — which passed with every hook body replaced by `{}`, and
    /// reached the app's real `UserDefaults` and cache directory to do it.
    static func install(
        account: MailAccountManager = .shared,
        notifier: MailNotifier = MailChecker.shared.notifier
    ) {
        guard SchoolMailAvailability.isEnabled else { return }
        SchoolMailCharsetHook.install()
        // A sign-out whose cache wipe never finished (the app was killed part-way through a
        // directory delete) leaves the previous student's mail on disk; finish it now, before
        // anything can sign in (§7.5).
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
        Task { await MailForegroundCheck.runIfDue() }
    }

    /// iOS expects the next refresh to be requested as the app leaves the foreground.
    static func sceneDidEnterBackground() {
        let account = MailAccountManager.shared
        guard MailBackgroundRefresh.shouldRescheduleAfterHandling(
            featureEnabled: SchoolMailAvailability.isEnabled,
            signedIn: account.isLoggedIn,
            notificationsEnabled: account.notificationsEnabled,
            authFailed: account.authFailed
        ) else { return }
        MailBackgroundRefresh.schedule()
    }
}
#endif
