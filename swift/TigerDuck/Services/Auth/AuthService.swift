import Defaults
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

    /// Secrets live at `.whenUnlockedThisDeviceOnly` (see ``SecureStore``), so keychain reads
    /// return nil while the device is locked. A process started behind a locked screen (push,
    /// background refresh, widget timeline reload) reads no credentials, and protected
    /// surfaces can show "not signed in" to a signed-in user.
    ///
    /// So this re-checks when protected data becomes available and when the app activates.
    /// Otherwise ``_revision`` moves only on login and logout, and after an unlock the Class
    /// Table stays on the login prompt until an unrelated redraw such as pull-to-refresh.
    init() {
        let present = storedStudentId != nil && storedPassword != nil
        lastKnownHasCredentials = present
        // Only ever raised here. A false read at this point may just mean the
        // keychain was not readable yet, which is not something to record.
        if present { Defaults[.ntustCredentialsPresent] = true }

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
        if current { Defaults[.ntustCredentialsPresent] = true }
        guard current != lastKnownHasCredentials else { return }
        lastKnownHasCredentials = current
        _revision &+= 1
    }

    /// Invalidate after a login or logout has moved the keychain, and
    /// re-snapshot so the next activation doesn't bump a second time.
    private func markCredentialsChanged() {
        let present = storedStudentId != nil && storedPassword != nil
        // The only authoritative read there is: we just wrote or cleared the
        // keychain ourselves, so a nil here really does mean absent. This is
        // the one path allowed to lower the mirror.
        Defaults[.ntustCredentialsPresent] = present
        lastKnownHasCredentials = present
        _revision &+= 1
    }

    var isNTUSTAuthenticated: Bool {
        _ = _revision
        return NTUSTSessionManager.shared.cookiesValid && storedStudentId != nil
    }

    /// The rule behind ``hasStoredCredentials``, which is true while the keychain still holds
    /// credentials. Protected surfaces gate on that rather than ``isNTUSTAuthenticated``, so a
    /// returning user whose cookies merely expired does not see the interactive login prompt;
    /// ``ensureAuthenticated()`` re-authenticates silently on the next fetch.
    ///
    /// Split out so it can be tested without a keychain, and so the direction is pinned: an
    /// OR, where the keychain wins when it has an answer and the mirror covers it when it
    /// does not.
    static func resolveHasCredentials(keychainSaysPresent: Bool, mirrorSaysPresent: Bool) -> Bool {
        keychainSaysPresent || mirrorSaysPresent
    }

    var hasStoredCredentials: Bool {
        _ = _revision
        if storedStudentId != nil && storedPassword != nil { return true }
        // A nil read means absent or just unreadable, so fall back to `ntustCredentialsPresent`:
        // readable when the keychain is not, lowered only by a real logout. Revalidation bumps
        // `_revision` only on change, so two nil reads would strand a signed-in user at login.
        return Self.resolveHasCredentials(
            keychainSaysPresent: false,
            mirrorSaysPresent: Defaults[.ntustCredentialsPresent]
        )
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

    private static let ssoServiceURL = URL.knownGood("https://courseselection.ntust.edu.tw/")

    func login(studentId: String, password: String) async -> Bool {
        isLoggingIn = true
        loginError = nil

        do {
            let session = NTUSTSessionManager.shared.session
            let normalizedId = studentId.trimmingCharacters(in: .whitespaces).uppercased()

            let success = try await SSOLoginService.ensureServiceLogin(
                session: session,
                serviceURL: Self.ssoServiceURL,
                studentId: normalizedId,
                password: password,
                generation: NTUSTSessionManager.shared.generation
            )

            if success {
                KeychainManager.saveString(key: AppConstants.KeychainKeys.studentId, value: normalizedId)
                KeychainManager.saveString(key: AppConstants.KeychainKeys.password, value: password)
                // Drop this account's cached enrolled courses so the first fetch after login
                // scrapes fresh data, not stale courses from before a semester crossover.
                CourseSelectionService.invalidateEnrolledCoursesCache(for: normalizedId)
                reauthErrorMessage = nil
                markCredentialsChanged()

                await loginToLibraryIfNeeded(studentId: normalizedId, password: password)

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
        let generation = NTUSTSessionManager.shared.generation

        // Ask the server whether the cookies still unlock the SSO home (~30ms warm). The
        // local 1h TTL errs both ways: it drops working cookies after an hour and trusts
        // ones the server has already evicted.
        if await NTUSTSessionManager.shared.probeCookiesValid() {
            NTUSTSessionManager.shared.markLoginSuccess()
            reauthErrorMessage = nil
            await ensureBackendSignedIn()
            return true
        }

        isReauthenticating = true
        reauthErrorMessage = nil
        let success = await renewSchoolSession(
            studentId: studentId, password: password, generation: generation
        )
        isReauthenticating = false

        if !success {
            // Keep credentials so the user can retry interactively — they
            // are the only party who can tell "cookie TTL" apart from
            // "password was changed on the portal".
            reauthErrorMessage = loginError ?? String(localized: "common_auto_sign_in_failed")
        }
        return success
    }

    /// The silent counterpart of ``login(studentId:password:)`` for stored credentials: it
    /// renews the SSO session only. The Moodle token outlives SSO cookies and every Moodle call
    /// renews it on `.invalidToken`, and the enrolled-course cache is still this account's.
    private func renewSchoolSession(studentId: String, password: String, generation: Int) async -> Bool {
        isLoggingIn = true
        loginError = nil
        defer { isLoggingIn = false }
        do {
            guard try await SSOLoginService.ensureServiceLogin(
                session: NTUSTSessionManager.shared.session,
                serviceURL: Self.ssoServiceURL,
                studentId: studentId,
                password: password,
                generation: generation
            ) else { return false }
        } catch is CancellationError {
            // The account signed out meanwhile; the login screen shows no error for it.
            return false
        } catch {
            if case SSOLoginError.loginFailed = error {} else {
                AppLogger.captureError(error, context: ["flow": "ntustReauth"])
            }
            loginError = error.localizedDescription
            return false
        }
        _revision &+= 1
        await loginToLibraryIfNeeded(studentId: studentId, password: password)
        await ensureBackendSignedIn()
        return true
    }

    /// Signs in to the TigerDuck backend when its session is gone. It sends the stored
    /// credentials and Moodle token and makes no request to the school's servers.
    func ensureBackendSignedIn() async {
        guard let atm = authTokenManager, !(await atm.isLoggedIn),
              let studentId = storedStudentId, let password = storedPassword else { return }
        await performV3Login(studentId: studentId, password: password)
    }

    /// Best-effort: the library account signs in with the same NTUST credentials.
    private func loginToLibraryIfNeeded(studentId: String, password: String) async {
        guard !LibraryService.isTokenValid else { return }
        do {
            _ = try await LibraryService.login(username: studentId, password: password)
        } catch {
            AppLogger.captureError(error, context: ["flow": "libraryAutoLogin"])
        }
    }

    func logout() {
        let loggingOutStudentId = storedStudentId
        KeychainManager.delete(key: AppConstants.KeychainKeys.studentId)
        KeychainManager.delete(key: AppConstants.KeychainKeys.password)
        Task { await MoodleTokenService.shared.clearToken() }
        MoodleEnrolledCoursesService.dropSharedAnswer()
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
