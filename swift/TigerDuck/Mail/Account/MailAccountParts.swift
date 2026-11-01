#if os(iOS)
import Foundation

struct MailAccountListeners {
    var signedIn: (() -> Void)?
    var signedOut: (() -> Void)?
    var authFailed: (() -> Void)?
    var notificationsEnabled: (() -> Void)?
    var notificationsDisabled: (() -> Void)?
    let signOutEvents: NotificationCenter
}

struct MailSignInParts {
    let credentials: MailCredentialStore
    let isDemoLogin: (String, String) -> Bool
    let makeClient: (Bool) -> any MailClient
    let schoolIsDemo: () -> Bool

    func client(demo: Bool) throws -> any MailClient {
        guard demo || !schoolIsDemo() else { throw MailClientError.unreachable }
        return makeClient(demo)
    }
}

struct MailLoginStatus: Equatable {
    var isLoggingIn = false
    var error: MailAccountManager.LoginError?
}

struct MailAuthFailure: Equatable {
    var isFailed: Bool
    var bannerDismissed = false
}

struct MailAccountSettings {
    var displayName: String?
    var notificationsEnabled: Bool
    var muteSettings: MailMuteSettings
}

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
