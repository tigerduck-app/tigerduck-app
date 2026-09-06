import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@Observable
final class AuthService {
    /// Bump to force SwiftUI re-evaluation of computed properties
    /// that read from external stores (Keychain, cookie jar).
    private var _revision = 0

    /// Monotonic counter that identifies the current login session. Bumped
    /// on logout so that any fetch already in flight at logout time can
    /// detect it (by capturing this value before the request and comparing
    /// before persisting) and skip writing the previous user's data back to
    /// disk. Cancelling the AppState `syncTask` only covers the AppState
    /// background sync; Home / Class Table / Calendar `refresh` paths run
    /// on their own Tasks that this generation check protects.
    private(set) var loginGeneration: Int = 0

    /// What the keychain answered the last time credentials demonstrably
    /// changed. Only used to keep ``revalidateStoredCredentials()`` from
    /// bumping ``_revision`` when nothing actually moved.
    private var lastKnownHasCredentials: Bool?

    private var credentialObservers: [any NSObjectProtocol] = []

    /// Secrets live at `.whenUnlockedThisDeviceOnly` (see ``SecureStore``),
    /// so every keychain read taken while the device is locked comes back
    /// nil. A process started behind a locked screen — push, background
    /// refresh, widget timeline reload — therefore comes up with
    /// ``hasStoredCredentials`` false, and protected surfaces render their
    /// "not signed in" prompt for a user who is signed in perfectly well.
    ///
    /// Nothing corrected that afterwards. ``_revision`` moved only on login
    /// and logout, so once the device was unlocked SwiftUI had no reason to
    /// re-read the keychain: the Class Table sat on the login prompt until
    /// some unrelated state change forced a redraw, which in practice meant
    /// pull-to-refresh. Re-check when protected data comes back and when the
    /// app activates.
    init() {
        lastKnownHasCredentials = storedStudentId != nil && storedPassword != nil

        #if os(iOS)
        let names: [Notification.Name] = [
            UIApplication.protectedDataDidBecomeAvailableNotification,
            UIApplication.didBecomeActiveNotification,
        ]
        #elseif os(macOS)
        let names: [Notification.Name] = [NSApplication.didBecomeActiveNotification]
        #else
        let names: [Notification.Name] = []
        #endif

        let center = NotificationCenter.default
        credentialObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.revalidateStoredCredentials() }
            }
        }
    }

    /// Re-read the keychain and invalidate only if its answer changed, so a
    /// routine foreground doesn't redraw every view that reads credentials.
    private func revalidateStoredCredentials() {
        let current = storedStudentId != nil && storedPassword != nil
        guard current != lastKnownHasCredentials else { return }
        lastKnownHasCredentials = current
        _revision &+= 1
    }

    /// Invalidate after a login or logout has moved the keychain, and
    /// re-snapshot so the next activation doesn't bump a second time.
    private func markCredentialsChanged() {
        lastKnownHasCredentials = storedStudentId != nil && storedPassword != nil
        _revision &+= 1
    }

    var isNTUSTAuthenticated: Bool {
        _ = _revision
        return NTUSTSessionManager.shared.cookiesValid && storedStudentId != nil
    }

    /// True when the keychain still holds credentials. Protected surfaces
    /// gate on this rather than on ``isNTUSTAuthenticated`` so that a
    /// returning user whose cookies have simply TTL'd does NOT see the
    /// interactive login prompt — ``ensureAuthenticated()`` will silently
    /// re-authenticate on the next fetch.
    var hasStoredCredentials: Bool {
        _ = _revision
        return storedStudentId != nil && storedPassword != nil
    }

    /// True while a silent re-authentication (triggered by
    /// ``ensureAuthenticated()``) is in flight. Distinct from
    /// ``isLoggingIn`` which covers both interactive and silent paths —
    /// consumers that want to distinguish "user is typing into the login
    /// sheet" from "background re-auth" read this instead.
    var isReauthenticating = false

    /// Last silent re-auth failure (e.g. password was changed on the
    /// portal). Credentials are intentionally retained — the user decides
    /// whether to retry interactively. Cleared on the next successful
    /// login or logout.
    var reauthErrorMessage: String?

    var isLoggingIn = false
    var loginError: String?

    var authTokenManager: AuthTokenManager?
    var onV3SignedIn: (() -> Void)?

    var storedStudentId: String? {
        _ = _revision
        return KeychainManager.loadString(key: AppConstants.KeychainKeys.studentId)
    }

    var storedPassword: String? {
        _ = _revision
        return KeychainManager.loadString(key: AppConstants.KeychainKeys.password)
    }

    func login(studentId: String, password: String) async -> Bool {
        isLoggingIn = true
        loginError = nil

        do {
            let session = NTUSTSessionManager.shared.session
            let serviceURL = URL.knownGood("https://courseselection.ntust.edu.tw/")
            let normalizedId = studentId.trimmingCharacters(in: .whitespaces).uppercased()

            let success = try await SSOLoginService.ensureServiceLogin(
                session: session,
                serviceURL: serviceURL,
                studentId: normalizedId,
                password: password
            )

            if success {
                KeychainManager.saveString(key: AppConstants.KeychainKeys.studentId, value: normalizedId)
                KeychainManager.saveString(key: AppConstants.KeychainKeys.password, value: password)
                // Drop any cached enrolled course list for this account
                // so the first post-login fetch scrapes fresh data;
                // prevents showing stale courses after e.g. an end-of-
                // semester crossover.
                CourseSelectionService.invalidateEnrolledCoursesCache(for: normalizedId)
                reauthErrorMessage = nil
                markCredentialsChanged()

                // Auto-attempt library login with same credentials (best-effort)
                if !LibraryService.isTokenValid {
                    do {
                        _ = try await LibraryService.login(username: normalizedId, password: password)
                    } catch {
                        AppLogger.captureError(error, context: ["flow": "libraryAutoLogin"])
                    }
                }

                // Obtain Moodle webservice token — non-fatal, never blocks NTUST login result
                do {
                    _ = try await MoodleTokenService.shared.obtainToken(studentId: normalizedId, password: password)
                } catch {
                    AppLogger.captureError(error, context: ["flow": "moodleTokenObtain"])
                }

                await performV3Login(studentId: normalizedId, password: password)
            }

            isLoggingIn = false
            return success
        } catch {
            // SSOLoginError.loginFailed is a user-facing outcome (wrong
            // credentials); reporting it would inflate Sentry counts and
            // drown out real infrastructure failures.
            if case SSOLoginError.loginFailed = error {} else {
                AppLogger.captureError(error, context: ["flow": "ntustLogin"])
            }
            loginError = error.localizedDescription
            isLoggingIn = false
            return false
        }
    }

    private func performV3Login(studentId: String, password: String) async {
        guard let authTokenManager else { return }
        guard let moodleToken = await MoodleTokenService.shared.currentToken(),
              !moodleToken.isEmpty else {
            return
        }
        let moodlePrivateToken = KeychainManager.loadString(
            key: AppConstants.KeychainKeys.moodlePrivateToken
        )
        let platform = PushDeviceClass.platform(for: PushDeviceClass.resolvedForBuild)
        do {
            _ = try await authTokenManager.login(
                studentId: studentId,
                password: password,
                moodleToken: moodleToken,
                moodlePrivateToken: moodlePrivateToken,
                platform: platform
            )
            onV3SignedIn?()
        } catch {
            AppLogger.captureError(error, context: ["flow": "v3Login"])
        }
    }

    /// Silent re-authenticate using stored credentials. Distinct from
    /// ``login(studentId:password:)`` in that it manages
    /// ``isReauthenticating`` / ``reauthErrorMessage`` around the attempt,
    /// so UI surfaces can distinguish a background refresh from the user
    /// interactively typing into the login sheet.
    func ensureAuthenticated() async -> Bool {
        guard let studentId = storedStudentId, let password = storedPassword else {
            return false
        }

        // Ask the server directly whether our cookies still unlock the
        // SSO home (~30ms warm). Obsoletes the local 1h TTL check which
        // was both paranoid (kicked fresh cookies off the cliff after
        // an hour) and optimistic (could trust cookies the server had
        // already evicted).
        if await NTUSTSessionManager.shared.probeCookiesValid() {
            NTUSTSessionManager.shared.markLoginSuccess()
            reauthErrorMessage = nil
            if let atm = authTokenManager, !(await atm.isLoggedIn) {
                await performV3Login(studentId: studentId, password: password)
            }
            return true
        }

        isReauthenticating = true
        reauthErrorMessage = nil
        let success = await login(studentId: studentId, password: password)
        isReauthenticating = false

        if !success {
            // Keep credentials so the user can retry interactively — they
            // are the only party who can tell "cookie TTL" apart from
            // "password was changed on the portal".
            reauthErrorMessage = loginError ?? String(localized: "common_auto_sign_in_failed")
        }
        return success
    }

    func logout() {
        let loggingOutStudentId = storedStudentId
        KeychainManager.delete(key: AppConstants.KeychainKeys.studentId)
        KeychainManager.delete(key: AppConstants.KeychainKeys.password)
        Task { await MoodleTokenService.shared.clearToken() }
        NTUSTSessionManager.shared.invalidateSession()
        // Drop the enrolled-courses cache so the next user does not see
        // the previous account's course list while their own data is
        // still in flight.
        CourseSelectionService.invalidateEnrolledCoursesCache(for: loggingOutStudentId)
        loginError = nil
        reauthErrorMessage = nil
        isReauthenticating = false
        loginGeneration &+= 1
        markCredentialsChanged()
    }

    func clearReauthError() {
        reauthErrorMessage = nil
    }
}
