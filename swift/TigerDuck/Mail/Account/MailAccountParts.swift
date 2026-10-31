#if os(iOS)
import Foundation

/// Who hears about School Mail's account: the app's hooks for a sign-in, a sign-out, a rejected
/// password and the notification switch, and the mail pages listening for `didSignOut`.
struct MailAccountListeners {
    var signedIn: (() -> Void)?
    var signedOut: (() -> Void)?
    var authFailed: (() -> Void)?
    var notificationsEnabled: (() -> Void)?
    var notificationsDisabled: (() -> Void)?
    let signOutEvents: NotificationCenter
}

/// How a sign-in reaches the server: the stored password, and the client for the real server or
/// the demo account.
struct MailSignInParts {
    let credentials: MailCredentialStore
    let isDemoLogin: (String, String) -> Bool
    let makeClient: (Bool) -> any MailClient
}

/// The state of the sign-in the user started.
struct MailLoginStatus: Equatable {
    var isLoggingIn = false
    var error: MailAccountManager.LoginError?
}

/// A password the server refused, and whether the user put its banner away since.
struct MailAuthFailure: Equatable {
    var isFailed: Bool
    var bannerDismissed = false
}

/// The settings the user gives School Mail, mirrored in `MailPreferences`.
struct MailAccountSettings {
    var displayName: String?
    var notificationsEnabled: Bool
    var muteSettings: MailMuteSettings
}

/// The wipe of School Mail's cache a sign-out starts, which the next sign-in waits for and a
/// launch finishes when the app quit before it did.
@MainActor
final class MailCacheWipe {
    let cache: MailCache
    private let clear: @Sendable () async -> Void
    private(set) var pending: Task<Void, Never>?

    init(cache: MailCache, clear: (@Sendable () async -> Void)?) {
        self.cache = cache
        self.clear = clear ?? { cache.clearAll() }
    }

    func start(prefs: any MailPreferences) {
        let performClear = clear
        prefs.cacheWipePending = true
        pending = Task.detached {
            await performClear()
            prefs.cacheWipePending = false
        }
    }

    func resumeIfInterrupted(prefs: any MailPreferences) {
        guard prefs.cacheWipePending, pending == nil else { return }
        start(prefs: prefs)
    }

    func forgetFinished() {
        pending = nil
    }
}
#endif
