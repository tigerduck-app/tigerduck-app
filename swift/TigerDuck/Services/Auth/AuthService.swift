import Defaults
import Foundation
import os
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
    /// changed. ``hasStoredCredentials`` answers from it, and it keeps
    /// ``revalidateStoredCredentials()`` from bumping ``_revision`` when
    /// nothing actually moved.
    private var lastKnownHasCredentials: Bool?

    /// Whether the keychain holds both credentials; two keychain reads.
    private let keychainHasCredentials: () -> Bool

    private let moodleTokens: MoodleTokenService

    /// The interactive SSO sign-in. Tests pass a stand-in, so no request reaches the school.
    private let schoolSignIn: (_ studentId: String, _ password: String) async throws -> Bool

    private var credentialObservers: [any NSObjectProtocol] = []

    /// Secrets live at `.whenUnlockedThisDeviceOnly` (see ``SecureStore``), so keychain reads
    /// return nil while the device is locked. A process started behind a locked screen (push,
    /// background refresh, widget timeline reload) reads no credentials, and protected
    /// surfaces can show "not signed in" to a signed-in user.
    ///
    /// So this re-checks when protected data becomes available and when the app activates.
    /// Otherwise ``_revision`` moves only on login and logout, and after an unlock the Class
    /// Table stays on the login prompt until an unrelated redraw such as pull-to-refresh.
    init(
        keychainHasCredentials: @escaping () -> Bool = AuthService.readKeychainHasCredentials,
        notificationCenter center: NotificationCenter = .default,
        moodleTokens: MoodleTokenService = .shared,
        schoolSignIn: @escaping (_ studentId: String, _ password: String) async throws -> Bool
            = AuthService.signInToSchool
    ) {
        self.keychainHasCredentials = keychainHasCredentials
        self.moodleTokens = moodleTokens
        self.schoolSignIn = schoolSignIn
        let present = keychainHasCredentials()
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

        credentialObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.revalidateStoredCredentials() }
            }
        }
        #if os(iOS)
        // A relogin behind a locked screen fails for want of the Moodle token, and the unlock
        // makes it readable again.
        credentialObservers.append(center.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.signInAfterUnlock() }
        })
        let returnToApp = UIApplication.didBecomeActiveNotification
        #elseif os(macOS)
        let returnToApp = NSApplication.didBecomeActiveNotification
        #endif
        #if os(iOS) || os(macOS)
        // A sign-in that failed for another reason gets another try on each return to the app.
        credentialObservers.append(center.addObserver(
            forName: returnToApp, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.ensureBackendSignedIn() }
        })
        #endif
    }

    /// Re-read the keychain and invalidate only if its answer changed, so a
    /// routine foreground doesn't redraw every view that reads credentials.
    private func revalidateStoredCredentials() {
        let current = keychainHasCredentials()
        if current { Defaults[.ntustCredentialsPresent] = true }
        guard current != lastKnownHasCredentials else { return }
        lastKnownHasCredentials = current
        _revision &+= 1
    }

    /// Invalidate after a login or logout has moved the keychain, and
    /// re-snapshot so the next activation doesn't bump a second time.
    private func markCredentialsChanged() {
        let present = keychainHasCredentials()
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

    /// Answers from the last keychain read, not a new one: screens such as the Class Table
    /// read this several times per redraw.
    var hasStoredCredentials: Bool {
        _ = _revision
        // A nil read means absent or just unreadable, so fall back to `ntustCredentialsPresent`:
        // readable when the keychain is not, lowered only by a real logout. Revalidation bumps
        // `_revision` only on change, so two nil reads would strand a signed-in user at login.
        return Self.resolveHasCredentials(
            keychainSaysPresent: lastKnownHasCredentials ?? false,
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
    /// The full sign-out, `AppState.logoutNTUST()`. ``login(studentId:password:)`` waits for it
    /// when another student ID signs in over the stored one, so that student inherits none of the
    /// stored account's data. It also empties the school session, which the SSO sign-in would
    /// otherwise accept as signed in without checking the new password.
    var signOutStoredAccount: (() async -> Void)?
    /// The calls a sign-out still sends as the departing account, the device's unregister among
    /// them, which `AppState.logoutNTUST()` hands over. Landing after a sign-in, the unregister
    /// would revoke the session and push tokens that sign-in registers.
    var signOutCalls: Task<Void, Never>?
    @ObservationIgnored private var backendSignIn: Task<Void, Never>?
    /// When an automatic backend sign-in that had credentials to send last failed. The backend
    /// takes five logins per student and per IP in 15 minutes (`auth_login_max_attempts` in
    /// https://github.com/tigerduck-app/tigerduck-backend/blob/main/server/config.py), and a
    /// campus network puts many students behind one IP, so the next automatic one waits
    /// ``backendSignInPause``.
    @ObservationIgnored private var backendSignInFailedAt: Date?

    nonisolated static let backendSignInPause: TimeInterval = 5 * 60

    /// Whether an automatic backend sign-in may go. Measured from the failure, so a clock set
    /// back does not stretch the pause.
    nonisolated static func backendSignInIsDue(lastFailure: Date?, now: Date) -> Bool {
        guard let lastFailure else { return true }
        let age = now.timeIntervalSince(lastFailure)
        return age >= backendSignInPause || age < 0
    }

    /// True while an automatic backend sign-in that had credentials to send is under way.
    private(set) var isSigningInToBackend = false

    /// Whether the TigerSync status asks the user to sign in again, in place of the error left by a
    /// registration that went unsent because an automatic sign-in failed. Not while another is
    /// under way, which may yet succeed. The school sign-in it opens signs in to the backend too.
    nonisolated static func asksToSignInAgain(
        syncEnabled: Bool,
        credentialsReadable: Bool,
        hasBackendSession: Bool,
        signingIn: Bool,
        registrationFoundNoSession: Bool
    ) -> Bool {
        syncEnabled && credentialsReadable && !hasBackendSession && !signingIn && registrationFoundNoSession
    }

    /// ``asksToSignInAgain(syncEnabled:credentialsReadable:hasBackendSession:signingIn:registrationFoundNoSession:)``
    /// for this device now, after the registration `registration` describes.
    func asksToSignInAgain(syncEnabled: Bool, after registration: PushRegistrationSnapshot) async -> Bool {
        guard let authTokenManager else { return false }
        let hasBackendSession = await authTokenManager.isLoggedIn
        return Self.asksToSignInAgain(
            syncEnabled: syncEnabled,
            credentialsReadable: storedStudentId != nil && storedPassword != nil,
            hasBackendSession: hasBackendSession,
            signingIn: isSigningInToBackend,
            registrationFoundNoSession: registration.lastAttemptFoundNoSession
        )
    }

    var storedStudentId: String? {
        _ = _revision
        return KeychainManager.loadString(key: AppConstants.KeychainKeys.studentId)
    }

    var storedPassword: String? {
        _ = _revision
        return KeychainManager.loadString(key: AppConstants.KeychainKeys.password)
    }

    nonisolated static func readKeychainHasCredentials() -> Bool {
        KeychainManager.loadString(key: AppConstants.KeychainKeys.studentId) != nil
            && KeychainManager.loadString(key: AppConstants.KeychainKeys.password) != nil
    }

    private static let ssoServiceURL = URL.knownGood("https://courseselection.ntust.edu.tw/")

    /// Reads the session generation when it starts, which is after the sign-out that
    /// ``login(studentId:password:)`` runs first for another student ID.
    static func signInToSchool(studentId: String, password: String) async throws -> Bool {
        try await SSOLoginService.ensureServiceLogin(
            session: NTUSTSessionManager.shared.session,
            serviceURL: ssoServiceURL,
            studentId: studentId,
            password: password,
            generation: NTUSTSessionManager.shared.generation,
            interactive: true
        )
    }

    func login(studentId: String, password: String) async -> Bool {
        isLoggingIn = true
        loginError = nil

        do {
            let normalizedId = studentId.trimmingCharacters(in: .whitespaces).uppercased()
            await signOutCalls?.value
            if let stored = storedStudentId, stored != normalizedId {
                await signOutStoredAccount?()
            }

            let success = try await schoolSignIn(normalizedId, password)

            if success {
                KeychainManager.saveString(key: AppConstants.KeychainKeys.studentId, value: normalizedId)
                KeychainManager.saveString(key: AppConstants.KeychainKeys.password, value: password)
                // Drop this account's cached enrolled courses so the first fetch after login
                // scrapes fresh data, not stale courses from before a semester crossover.
                CourseSelectionService.invalidateEnrolledCoursesCache(for: normalizedId)
                // Class tables imported while no one was signed in become this account's.
                ImportedClassTableStore.shared.accountDidSignIn(studentId: normalizedId)
                reauthErrorMessage = nil
                markCredentialsChanged()

                await signInToServices(studentId: normalizedId, password: password, generation: loginGeneration)
            }

            isLoggingIn = false
            return success
        } catch {
            // SSOLoginError.loginFailed is a user-facing outcome (wrong
            // credentials); logging it as an error would drown out real
            // infrastructure failures.
            if case SSOLoginError.loginFailed = error {} else {
                AppLogger.captureError(error, context: ["flow": "ntustLogin"])
            }
            loginError = error.localizedDescription
            isLoggingIn = false
            return false
        }
    }

    /// The sign-ins after the school's: the library, the Moodle token and the backend. A sign-out
    /// while one waits on the network moves `loginGeneration` off `generation`, and the later
    /// steps then store nothing for the account that left.
    func signInToServices(studentId: String, password: String, generation: Int) async {
        await loginToLibraryIfNeeded(studentId: studentId, password: password)
        guard loginGeneration == generation else { return }
        // Non-fatal: the school sign-in has already succeeded.
        do {
            _ = try await moodleTokens.obtainToken(studentId: studentId, password: password)
        } catch {
            AppLogger.captureError(error, context: ["flow": "moodleTokenObtain"])
        }
        guard loginGeneration == generation else { return }
        await performV3Login(studentId: studentId)
    }

    /// Signs in to the backend with the stored Moodle token and returns whether it did. With
    /// `harvesting`, a missing token is harvested first; the interactive sign-in passes false,
    /// as it has just tried to harvest one.
    @discardableResult
    private func performV3Login(studentId: String, harvesting: Bool = false) async -> Bool {
        guard let authTokenManager else { return false }
        let generation = loginGeneration
        let moodleToken = harvesting ? await moodleTokenForBackend() : await moodleTokens.currentToken()
        guard let moodleToken, !moodleToken.isEmpty, loginGeneration == generation else { return false }
        let moodlePrivateToken = KeychainManager.loadString(
            key: AppConstants.KeychainKeys.moodlePrivateToken
        )
        let platform = PushDeviceClass.platform(for: PushDeviceClass.resolvedForBuild)
        do {
            _ = try await authTokenManager.login(
                studentId: studentId,
                moodleToken: moodleToken,
                moodlePrivateToken: moodlePrivateToken,
                platform: platform
            )
            // Signed out while the request was out: the session is the departing account's.
            guard loginGeneration == generation else { return false }
            backendSignInFailedAt = nil
            onV3SignedIn?()
            return true
        } catch {
            guard loginGeneration == generation else { return false }
            AppLogger.captureError(error, context: ["flow": "v3Login"])
            return false
        }
    }

    /// Signs in to the backend again after it turned the session down, from a refresh or a
    /// request answered 401. It sends the Moodle token and no password.
    func reloginToBackend() async -> Bool {
        guard let authTokenManager,
              Self.backendSignInIsDue(lastFailure: backendSignInFailedAt, now: Date()),
              let studentId = storedStudentId else { return false }
        let generation = loginGeneration
        guard let moodleToken = await moodleTokenForBackend(), loginGeneration == generation else {
            AppLogger.sync.info("auto-relogin skipped: no Moodle token")
            noteFailedBackendSignIn(since: generation)
            return false
        }
        let moodlePrivateToken = KeychainManager.loadString(
            key: AppConstants.KeychainKeys.moodlePrivateToken
        )
        let platform = PushDeviceClass.platform(for: PushDeviceClass.resolvedForBuild)
        do {
            _ = try await authTokenManager.login(
                studentId: studentId,
                moodleToken: moodleToken,
                moodlePrivateToken: moodlePrivateToken,
                platform: platform
            )
            AppLogger.sync.info("auto-relogin: v3 JWT refreshed")
            backendSignInFailedAt = nil
            return true
        } catch {
            AppLogger.sync.error("auto-relogin failed: \(error, privacy: .private)")
            noteFailedBackendSignIn(since: generation)
            return false
        }
    }

    /// Starts the pause after an automatic sign-in failed, unless the account signed out
    /// meanwhile: then the failure was the departing account's.
    private func noteFailedBackendSignIn(since generation: Int) {
        guard loginGeneration == generation else { return }
        backendSignInFailedAt = Date()
    }

    /// The stored Moodle token, or one harvested with the stored credentials when none is
    /// stored: a backend sign-in proves the account with it. Nil when that fails. Behind a
    /// locked screen the credentials are unreadable too, and no request goes out.
    private func moodleTokenForBackend() async -> String? {
        do {
            let token = try await moodleTokens.refreshTokenIfNeeded()
            return token.isEmpty ? nil : token
        } catch {
            let line = AppLogger.errorLine(error, context: [:])
            AppLogger.auth.info("no Moodle token for the backend: \(line, privacy: .private)")
            return nil
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
    /// renews it on `.invalidToken`, and the enrolled-course cache is still this account's. The
    /// library token is renewed by `LibraryService.signInIfCredentialed()`, which stops after a
    /// refusal and keeps a library sign-out.
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
        await ensureBackendSignedIn()
        return true
    }

    /// Signs in to the TigerDuck backend when its session is gone. It sends the stored
    /// credentials and Moodle token, and reaches the school's servers only to harvest a token
    /// when none is stored. A call while one runs waits for it instead of signing in again, and
    /// for ``backendSignInPause`` after one that failed, calls do nothing.
    func ensureBackendSignedIn() async {
        if let backendSignIn { return await backendSignIn.value }
        let task = Task { await signInToBackendIfSignedOut() }
        backendSignIn = task
        await task.value
        if backendSignIn == task { backendSignIn = nil }
    }

    /// A sign-in already running may have begun behind the locked screen, where the credentials
    /// could not be read, so the unlock waits for it and then tries on its own.
    private func signInAfterUnlock() async {
        if let running = backendSignIn {
            await running.value
            if backendSignIn == running { backendSignIn = nil }
        }
        // A sign-in that failed around the lock may have lost the keychain or the network to it,
        // so the unlock does not wait out its pause.
        backendSignInFailedAt = nil
        await ensureBackendSignedIn()
    }

    private func signInToBackendIfSignedOut() async {
        guard let atm = authTokenManager, !(await atm.isLoggedIn),
              Self.backendSignInIsDue(lastFailure: backendSignInFailedAt, now: Date()),
              let studentId = storedStudentId, storedPassword != nil else { return }
        let generation = loginGeneration
        isSigningInToBackend = true
        defer { isSigningInToBackend = false }
        if await !performV3Login(studentId: studentId, harvesting: true) {
            noteFailedBackendSignIn(since: generation)
        }
    }

    /// Best-effort: the library account signs in with the same NTUST credentials. A school
    /// sign-out while the request is out keeps nothing, as no library account of that ID is
    /// stored yet for the sign-out to clear.
    private func loginToLibraryIfNeeded(studentId: String, password: String) async {
        guard !LibraryService.isTokenValid else { return }
        let generation = loginGeneration
        do {
            _ = try await LibraryService.login(
                username: studentId,
                password: password,
                stillCurrent: { self.loginGeneration == generation }
            )
        } catch {
            AppLogger.captureError(error, context: ["flow": "libraryAutoLogin"])
        }
    }

    func logout() {
        let loggingOutStudentId = storedStudentId
        KeychainManager.delete(key: AppConstants.KeychainKeys.studentId)
        KeychainManager.delete(key: AppConstants.KeychainKeys.password)
        Task { [moodleTokens] in await moodleTokens.signOut() }
        MoodleEnrolledCoursesService.dropSharedAnswer()
        ClassroomUsageService.shared.forget()
        NTUSTSessionManager.shared.invalidateSession()
        // Drop the enrolled-courses cache so the next user does not see
        // the previous account's course list while their own data is
        // still in flight.
        CourseSelectionService.invalidateEnrolledCoursesCache(for: loggingOutStudentId)
        loginError = nil
        reauthErrorMessage = nil
        isReauthenticating = false
        loginGeneration &+= 1
        backendSignIn?.cancel()
        backendSignIn = nil
        backendSignInFailedAt = nil
        markCredentialsChanged()
    }

    func clearReauthError() {
        reauthErrorMessage = nil
    }
}
