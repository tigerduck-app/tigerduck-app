import Foundation
#if os(iOS)
import UIKit
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

    #if os(iOS)
    /// v3 JWT token store. Injected by ``AppState`` after init so a
    /// successful NTUST sign-in also mints the access/refresh tokens that
    /// authorize every `/v3` push + bulletin call. The login half of this
    /// store was previously never wired — the app held NTUST cookies but no
    /// Bearer, so every authed `/v3` request 401'd.
    var authTokenManager: AuthTokenManager?
    /// Fired (on the main actor) after a successful v3 login so the push
    /// stack can (re)register the device now that a Bearer exists. The
    /// launch-time registration runs before any JWT and 401s; this lets it
    /// recover the instant the user signs in.
    var onV3SignedIn: (() -> Void)?
    #endif

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
                _revision &+= 1

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

                #if os(iOS)
                // Mint the v3 JWT now that we hold NTUST creds + a Moodle
                // token. Must run AFTER the obtain above — the backend
                // verifies the Moodle wstoken and rejects login without it.
                // Best-effort: a v3 failure never blocks the NTUST session.
                await performV3Login(studentId: normalizedId, password: password)
                #endif
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

    #if os(iOS)
    /// Posts to `/v3/auth/login` to obtain JWT access/refresh tokens, then
    /// kicks the push stack to (re)register. The Moodle token (verified
    /// server-side) is read from the store the obtain step in
    /// ``login(studentId:password:)`` just populated; a previously cached
    /// token is reused if this login's obtain failed transiently, so a flaky
    /// Moodle hop doesn't strand push behind a missing Bearer.
    private func performV3Login(studentId: String, password: String) async {
        guard let authTokenManager else { return }
        guard let moodleToken = await MoodleTokenService.shared.currentToken(),
              !moodleToken.isEmpty else {
            // No verified Moodle token → the backend returns
            // moodle_verification_failed. Skip rather than 401-spin; the
            // next successful login retries.
            return
        }
        let moodlePrivateToken = KeychainManager.loadString(
            key: AppConstants.KeychainKeys.moodlePrivateToken
        )
        let platform = PushDeviceClass.platform(for: PushDeviceClass.resolvedForBuild)
        let deviceName = UIDevice.current.name
        do {
            _ = try await authTokenManager.login(
                studentId: studentId,
                password: password,
                moodleToken: moodleToken,
                moodlePrivateToken: moodlePrivateToken,
                platform: platform,
                deviceName: deviceName
            )
            // Bearer is now available — let the push stack recover the
            // launch-time registration that 401'd before we had a token.
            onV3SignedIn?()
        } catch {
            // Best-effort — the NTUST session already succeeded. Push and
            // authed bulletin calls retry on the next login / token refresh.
            AppLogger.captureError(error, context: ["flow": "v3Login"])
        }
    }
    #endif

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
        _revision &+= 1
    }

    func clearReauthError() {
        reauthErrorMessage = nil
    }
}
