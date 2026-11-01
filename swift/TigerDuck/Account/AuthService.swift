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
    let session: AccountSession
    private var credentials = CredentialMirror()
    var status = AuthStatus()
    @ObservationIgnored let deps: AuthServiceDependencies
    @ObservationIgnored private var hooks = AuthServiceHooks()
    @ObservationIgnored private(set) var signOutCalls: Task<Void, Never>?
    @ObservationIgnored private(set) var backend: BackendSignIn!
    @ObservationIgnored private(set) var passwordRetry: StoredPasswordRetry!
    @ObservationIgnored private var credentialObservers: [any NSObjectProtocol] = []

    /// Secrets live at `.whenUnlockedThisDeviceOnly` (see ``SecureStore``), so keychain reads
    /// return nil while the device is locked, and a process started behind a locked screen reads
    /// no credentials. This re-checks when protected data becomes available and when the app
    /// activates, or after an unlock the Class Table would stay on the login prompt.
    init(
        session: AccountSession = AccountSession(),
        keychainHasCredentials: @escaping () -> Bool = AuthService.readKeychainHasCredentials,
        notificationCenter center: NotificationCenter = .default,
        moodleTokens: MoodleTokenService = .shared,
        schoolSignIn: @escaping (_ studentId: String, _ password: String, _ signIn: SignIn) async throws -> Bool
            = SchoolSignIn.signIn,
        schoolSessionIsLive: @escaping (_ signIn: SignIn) async -> Bool
            = { await NTUSTSessionManager.shared.probeCookiesValid(for: $0) },
        renewSchoolSignIn: @escaping (_ studentId: String, _ password: String, _ signIn: SignIn) async throws -> Bool
            = SchoolSignIn.renew,
        retrySchoolSignIn: @escaping (
            _ studentId: String, _ password: String, _ signIn: SignIn, _ mayPost: () -> Bool
        ) async throws -> Bool = SchoolSignIn.retry,
        endSchoolSession: @escaping @MainActor (_ departingStudentId: String?) -> Void
            = AccountSignOutCleanup.endSchoolSession(departing:),
        now: @escaping () -> Date = { Date() },
        retrySleep: @escaping @Sendable (Duration) async -> Void = { try? await AppClock.sleep(until: ContinuousClock.now + $0) },
        demo: DemoAccount = .app
    ) {
        self.session = session
        deps = AuthServiceDependencies(
            keychainHasCredentials: keychainHasCredentials, moodleTokens: moodleTokens, schoolSignIn: schoolSignIn,
            schoolSessionIsLive: schoolSessionIsLive, renewSchoolSignIn: renewSchoolSignIn,
            retrySchoolSignIn: retrySchoolSignIn, endSchoolSession: endSchoolSession, now: now, retrySleep: retrySleep,
            demo: demo
        )
        let present = keychainHasCredentials()
        credentials.lastKnown = present
        if present { Defaults[.ntustCredentialsPresent] = true }
        backend = BackendSignIn(auth: self)
        passwordRetry = StoredPasswordRetry(auth: self)

        credentialObservers = AuthServiceObservers.observe(center, for: self)
    }

    var isReauthenticating: Bool { get { status.isReauthenticating } set { status.isReauthenticating = newValue } }
    var reauthErrorMessage: String? { get { status.reauthErrorMessage } set { status.reauthErrorMessage = newValue } }
    var isLoggingIn: Bool { get { status.isLoggingIn } set { status.isLoggingIn = newValue } }
    var loginError: String? { get { status.loginError } set { status.loginError = newValue } }
    var authTokenManager: AuthTokenManager? { get { hooks.authTokenManager } set { hooks.authTokenManager = newValue } }
    var onV3SignedIn: (() -> Void)? { get { hooks.onV3SignedIn } set { hooks.onV3SignedIn = newValue } }
    var signOutStoredAccount: (() async -> Void)? { get { hooks.signOutStoredAccount } set { hooks.signOutStoredAccount = newValue } }
    #if os(iOS)
    var accountNotifications: any DeliveredNotificationCenter { get { hooks.accountNotifications } set { hooks.accountNotifications = newValue } }
    #endif
    var beginSignOutBackgroundTask: @Sendable () async -> @Sendable () async -> Void { get { hooks.beginSignOutBackgroundTask } set { hooks.beginSignOutBackgroundTask = newValue } }
    var clearAllCachedPages: @MainActor () async -> Void { get { hooks.clearAllCachedPages } set { hooks.clearAllCachedPages = newValue } }
    var storedPasswordRetry: Task<Void, Never>? { passwordRetry.task }
    var isSigningInToBackend: Bool { backend.isSigningIn }

    func revalidateStoredCredentials() {
        let current = deps.keychainHasCredentials()
        if current { Defaults[.ntustCredentialsPresent] = true }
        guard current != credentials.lastKnown else { return }
        credentials.lastKnown = current
        credentials.revision.moveOn()
    }

    func markCredentialsChanged() {
        let present = deps.keychainHasCredentials()
        Defaults[.ntustCredentialsPresent] = present
        credentials.lastKnown = present
        credentials.revision.moveOn()
    }

    func noteSchoolSignInRenewed() {
        credentials.revision.moveOn()
    }

    var isNTUSTAuthenticated: Bool {
        credentials.revision.read { NTUSTSessionManager.shared.ssoLoginStampIsFresh && storedStudentId != nil }
    }

    static func resolveHasCredentials(keychainSaysPresent: Bool, mirrorSaysPresent: Bool) -> Bool {
        keychainSaysPresent || mirrorSaysPresent
    }

    var hasStoredCredentials: Bool {
        Self.resolveHasCredentials(
            keychainSaysPresent: credentials.lastKnown ?? false,
            mirrorSaysPresent: Defaults[.ntustCredentialsPresent]
        )
    }

    func startSignOutCalls(_ calls: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = signOutCalls
        let beginBackgroundTask = beginSignOutBackgroundTask
        let task = Task { @MainActor in
            let endBackgroundTask = await beginBackgroundTask()
            await previous?.value
            await clearAllCachedPages()
            await calls()
            #if os(iOS)
            await AccountSignOutCleanup.removeAccountNotifications(from: accountNotifications)
            #endif
            await endBackgroundTask()
        }
        signOutCalls = task
        return task
    }

    nonisolated static func backendSignInIsDue(lastFailure: Date?, now: Date) -> Bool {
        BackendSignIn.isDue(lastFailure: lastFailure, now: now)
    }

    nonisolated static func asksToSignInAgain(
        syncEnabled: Bool,
        credentialsReadable: Bool,
        hasBackendSession: Bool,
        signingIn: Bool,
        registrationFoundNoSession: Bool
    ) -> Bool {
        syncEnabled && credentialsReadable && !hasBackendSession && !signingIn && registrationFoundNoSession
    }

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
        credentials.revision.read { KeychainManager.loadString(key: AppConstants.KeychainKeys.studentId) }
    }

    var storedPassword: String? {
        credentials.revision.read { KeychainManager.loadString(key: AppConstants.KeychainKeys.password) }
    }

    nonisolated static func readKeychainHasCredentials() -> Bool {
        KeychainManager.loadString(key: AppConstants.KeychainKeys.studentId) != nil
            && KeychainManager.loadString(key: AppConstants.KeychainKeys.password) != nil
    }

    nonisolated static func normalizedStudentId(_ studentId: String) -> String {
        studentId.trimmingCharacters(in: .whitespaces).uppercased()
    }

    nonisolated static func replacesStoredAccount(stored: String?, signingInAs studentId: String) -> Bool {
        stored.map { $0 != normalizedStudentId(studentId) } ?? false
    }

    func login(studentId: String, password: String) async -> Bool {
        await SchoolAccountSignIn.login(studentId: studentId, password: password, auth: self)
    }

    func signInToServices(studentId: String, password: String, signIn: SignIn) async {
        guard signIn.isCurrent else { return }
        do {
            _ = try await deps.moodleTokens.obtainToken(studentId: studentId, password: password, for: signIn)
        } catch {
            AppLogger.captureError(error, context: ["flow": "moodleTokenObtain"])
        }
        guard signIn.isCurrent else { return }
        await backend.signIn(studentId: studentId, for: signIn)
    }

    func reloginToBackend(replacing refused: String? = nil, for signIn: SignIn) async -> Bool {
        await backend.relogin(replacing: refused, for: signIn)
    }

    func ensureAuthenticated(for signIn: SignIn) async -> Bool {
        await SchoolAccountSignIn.ensureAuthenticated(auth: self, for: signIn)
    }

    func ensureBackendSignedIn() async {
        await backend.ensureSignedIn()
    }

    func logout() {
        let loggingOutStudentId = storedStudentId
        KeychainManager.delete(key: AppConstants.KeychainKeys.studentId)
        KeychainManager.delete(key: AppConstants.KeychainKeys.password)
        Task { [moodleTokens = deps.moodleTokens] in await moodleTokens.signOut() }
        deps.endSchoolSession(loggingOutStudentId)
        status.loginError = nil
        status.reauthErrorMessage = nil
        status.isReauthenticating = false
        session.endSignIn()
        backend.reset()
        SchoolPasswordPosts.forgetStoredPasswordRefusals()
        passwordRetry.cancel()
        markCredentialsChanged()
        #if os(iOS)
        Task { [accountNotifications] in await AccountSignOutCleanup.removeAccountNotifications(from: accountNotifications) }
        #endif
    }

    func clearReauthError() {
        status.reauthErrorMessage = nil
    }
}
