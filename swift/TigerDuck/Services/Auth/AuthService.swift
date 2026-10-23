import Defaults
import Foundation
import os
#if os(iOS)
import UIKit
import UserNotifications
#elseif os(macOS)
import AppKit
#endif

@Observable
final class AuthService {
    private var _revision = 0

    private(set) var loginGeneration: Int = 0

    private var lastKnownHasCredentials: Bool?

    private let keychainHasCredentials: () -> Bool

    private let moodleTokens: MoodleTokenService

    private let schoolSignIn: (_ studentId: String, _ password: String) async throws -> Bool

    private let schoolSessionIsLive: () async -> Bool
    private let renewSchoolSignIn: (_ studentId: String, _ password: String, _ generation: Int) async throws -> Bool

    private let now: () -> Date
    private let retrySleep: @Sendable (Duration) async -> Void
    @ObservationIgnored private(set) var storedPasswordRetry: Task<Void, Never>?
    @ObservationIgnored private var storedPasswordRetryMisses = 0

    private let endSchoolSession: @MainActor (_ departingStudentId: String?) -> Void

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
            = AuthService.signInToSchool,
        schoolSessionIsLive: @escaping () async -> Bool = { await NTUSTSessionManager.shared.probeCookiesValid() },
        renewSchoolSignIn: @escaping (_ studentId: String, _ password: String, _ generation: Int) async throws -> Bool
            = AuthService.renewSignInToSchool,
        endSchoolSession: @escaping @MainActor (_ departingStudentId: String?) -> Void
            = AuthService.endSchoolSession(departing:),
        now: @escaping () -> Date = { Date() },
        retrySleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.keychainHasCredentials = keychainHasCredentials
        self.moodleTokens = moodleTokens
        self.schoolSignIn = schoolSignIn
        self.schoolSessionIsLive = schoolSessionIsLive
        self.renewSchoolSignIn = renewSchoolSignIn
        self.endSchoolSession = endSchoolSession
        self.now = now
        self.retrySleep = retrySleep
        let present = keychainHasCredentials()
        lastKnownHasCredentials = present
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
        credentialObservers.append(center.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.signInToBackendAgain() }
        })
        let returnToApp = UIApplication.didBecomeActiveNotification
        #elseif os(macOS)
        let returnToApp = NSApplication.didBecomeActiveNotification
        #endif
        #if os(iOS) || os(macOS)
        credentialObservers.append(center.addObserver(
            forName: returnToApp, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.ensureBackendSignedIn() }
        })
        #endif
        credentialObservers.append(center.addObserver(
            forName: SSOLoginService.storedPasswordPostWaits, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.armStoredPasswordRetry() }
        })
    }

    private func revalidateStoredCredentials() {
        let current = keychainHasCredentials()
        if current { Defaults[.ntustCredentialsPresent] = true }
        guard current != lastKnownHasCredentials else { return }
        lastKnownHasCredentials = current
        _revision &+= 1
    }

    private func markCredentialsChanged() {
        let present = keychainHasCredentials()
        Defaults[.ntustCredentialsPresent] = present
        lastKnownHasCredentials = present
        _revision &+= 1
    }

    var isNTUSTAuthenticated: Bool {
        _ = _revision
        return NTUSTSessionManager.shared.cookiesValid && storedStudentId != nil
    }

    static func resolveHasCredentials(keychainSaysPresent: Bool, mirrorSaysPresent: Bool) -> Bool {
        keychainSaysPresent || mirrorSaysPresent
    }

    var hasStoredCredentials: Bool {
        _ = _revision
        return Self.resolveHasCredentials(
            keychainSaysPresent: lastKnownHasCredentials ?? false,
            mirrorSaysPresent: Defaults[.ntustCredentialsPresent]
        )
    }

    var isReauthenticating = false

    var reauthErrorMessage: String?

    var isLoggingIn = false
    var loginError: String?

    var authTokenManager: AuthTokenManager?
    var onV3SignedIn: (() -> Void)?
    var signOutStoredAccount: (() async -> Void)?
    #if os(iOS)
    @ObservationIgnored var accountNotifications: any DeliveredNotificationCenter = UNUserNotificationCenter.current()
    #endif
    private(set) var signOutCalls: Task<Void, Never>?
    @ObservationIgnored var beginSignOutBackgroundTask: @Sendable () async -> @Sendable () async -> Void = {
        await AuthTokenManager.beginBackgroundTask(named: "Sign-out")
    }

    func startSignOutCalls(_ calls: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = signOutCalls
        let beginBackgroundTask = beginSignOutBackgroundTask
        let task = Task { @MainActor in
            let endBackgroundTask = await beginBackgroundTask()
            await previous?.value
            await calls()
            #if os(iOS)
            await Self.removeAccountNotifications(from: accountNotifications)
            #endif
            await endBackgroundTask()
        }
        signOutCalls = task
        return task
    }
    @ObservationIgnored private var backendSignIn: Task<Void, Never>?
    /// When an automatic backend sign-in that had credentials to send last failed. The backend
    /// takes five logins per student and per IP in 15 minutes (`auth_login_max_attempts` in
    /// https://github.com/tigerduck-app/tigerduck-backend/blob/main/server/config.py), and a
    /// campus network puts many students behind one IP, so the next automatic one waits
    /// ``backendSignInPause``.
    @ObservationIgnored private var backendSignInFailedAt: Date?

    nonisolated static let backendSignInPause: TimeInterval = 5 * 60

    nonisolated static func backendSignInIsDue(lastFailure: Date?, now: Date) -> Bool {
        guard let lastFailure else { return true }
        let age = now.timeIntervalSince(lastFailure)
        return age >= backendSignInPause || age < 0
    }

    private(set) var isSigningInToBackend = false

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

    static func renewSignInToSchool(studentId: String, password: String, generation: Int) async throws -> Bool {
        try await SSOLoginService.ensureServiceLogin(
            session: NTUSTSessionManager.shared.session,
            serviceURL: ssoServiceURL,
            studentId: studentId,
            password: password,
            generation: generation
        )
    }

    func login(studentId: String, password: String) async -> Bool {
        isLoggingIn = true
        loginError = nil
        var schoolStepGeneration: Int?

        do {
            let normalizedId = studentId.trimmingCharacters(in: .whitespaces).uppercased()
            await signOutCalls?.value
            try Task.checkCancellation()
            if let stored = storedStudentId, stored != normalizedId {
                await signOutStoredAccount?()
                try Task.checkCancellation()
            }
            let generation = loginGeneration
            schoolStepGeneration = generation

            let success = try await schoolSignIn(normalizedId, password)
            guard loginGeneration == generation, !Task.isCancelled else {
                isLoggingIn = false
                return false
            }

            if success {
                KeychainManager.saveString(key: AppConstants.KeychainKeys.studentId, value: normalizedId)
                KeychainManager.saveString(key: AppConstants.KeychainKeys.password, value: password)
                CourseSelectionService.invalidateEnrolledCoursesCache(for: normalizedId)
                ImportedClassTableStore.shared.accountDidSignIn(studentId: normalizedId)
                reauthErrorMessage = nil
                markCredentialsChanged()

                await Task {
                    await signInToServices(studentId: normalizedId, password: password, generation: generation)
                }.value
            }

            isLoggingIn = false
            return success
        } catch where Task.isCancelled || schoolStepGeneration.map({ $0 != loginGeneration }) == true {
            isLoggingIn = false
            return false
        } catch {
            if case SSOLoginError.loginFailed = error {} else {
                AppLogger.captureError(error, context: ["flow": "ntustLogin"])
            }
            loginError = error.localizedDescription
            isLoggingIn = false
            return false
        }
    }

    func signInToServices(studentId: String, password: String, generation: Int) async {
        guard loginGeneration == generation else { return }
        do {
            _ = try await moodleTokens.obtainToken(studentId: studentId, password: password)
        } catch {
            AppLogger.captureError(error, context: ["flow": "moodleTokenObtain"])
        }
        guard loginGeneration == generation else { return }
        await performV3Login(studentId: studentId)
    }

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

    private func noteFailedBackendSignIn(since generation: Int) {
        guard loginGeneration == generation else { return }
        backendSignInFailedAt = Date()
    }

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

    func ensureAuthenticated() async -> Bool {
        guard let studentId = storedStudentId, let password = storedPassword else {
            return false
        }
        let generation = NTUSTSessionManager.shared.generation

        if await schoolSessionIsLive() {
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
            reauthErrorMessage = loginError ?? String(localized: "common_auto_sign_in_failed")
        }
        return success
    }

    private func renewSchoolSession(studentId: String, password: String, generation: Int) async -> Bool {
        isLoggingIn = true
        loginError = nil
        defer { isLoggingIn = false }
        do {
            guard try await renewSchoolSignIn(studentId, password, generation) else { return false }
        } catch is CancellationError {
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

    func ensureBackendSignedIn() async {
        if let backendSignIn { return await backendSignIn.value }
        let task = Task { await signInToBackendIfSignedOut() }
        backendSignIn = task
        await task.value
        if backendSignIn == task { backendSignIn = nil }
    }

    private func signInToBackendAgain() async {
        if let running = backendSignIn {
            await running.value
            if backendSignIn == running { backendSignIn = nil }
        }
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

    private func armStoredPasswordRetry() {
        storedPasswordRetryMisses = 0
        guard let retryAt = SSOLoginService.storedPasswordRetryAt(now: now()) else {
            storedPasswordRetry?.cancel()
            storedPasswordRetry = nil
            return
        }
        startStoredPasswordRetry(after: max(0, retryAt.timeIntervalSince(now())))
    }

    private func armStoredPasswordRetryAfterAMiss() {
        let refusals = SSOLoginService.storedPasswordRefusals.count
        guard refusals > 0 else { return }
        storedPasswordRetryMisses += 1
        startStoredPasswordRetry(
            after: SSOLoginService.storedPasswordRetryDelay(afterRefusals: refusals + storedPasswordRetryMisses)
        )
    }

    private func startStoredPasswordRetry(after wait: TimeInterval) {
        storedPasswordRetry?.cancel()
        let generation = loginGeneration
        storedPasswordRetry = Task { [weak self, retrySleep] in
            await retrySleep(.seconds(wait))
            guard !Task.isCancelled, let self, self.loginGeneration == generation else { return }
            self.storedPasswordRetry = nil
            await self.retryStoredPassword()
        }
    }

    private func retryStoredPassword() async {
        guard let retryAt = SSOLoginService.storedPasswordRetryAt(now: now()) else { return }
        guard retryAt <= now() else {
            armStoredPasswordRetry()
            return
        }
        let refusals = SSOLoginService.storedPasswordRefusals.count
        guard await !runStoredPasswordRetry(), SSOLoginService.storedPasswordRefusals.count == refusals else {
            return
        }
        armStoredPasswordRetryAfterAMiss()
    }

    private func runStoredPasswordRetry() async -> Bool {
        guard !isLoggingIn, let studentId = storedStudentId, let password = storedPassword else { return false }
        let generation = loginGeneration
        let sessionGeneration = NTUSTSessionManager.shared.generation
        if await !schoolSessionIsLive() {
            guard !isLoggingIn,
                  (try? await renewSchoolSignIn(studentId, password, sessionGeneration)) == true else { return false }
            _revision &+= 1
        }
        guard loginGeneration == generation else { return false }
        reauthErrorMessage = nil
        guard (try? await moodleTokens.refreshTokenIfNeeded()) != nil, loginGeneration == generation else { return false }
        await signInToBackendAgain()
        return true
    }

    func logout() {
        let loggingOutStudentId = storedStudentId
        KeychainManager.delete(key: AppConstants.KeychainKeys.studentId)
        KeychainManager.delete(key: AppConstants.KeychainKeys.password)
        Task { [moodleTokens] in await moodleTokens.signOut() }
        endSchoolSession(loggingOutStudentId)
        loginError = nil
        reauthErrorMessage = nil
        isReauthenticating = false
        loginGeneration &+= 1
        backendSignIn?.cancel()
        backendSignIn = nil
        backendSignInFailedAt = nil
        SSOLoginService.forgetStoredPasswordRefusals()
        storedPasswordRetry?.cancel()
        storedPasswordRetry = nil
        markCredentialsChanged()
        #if os(iOS)
        Task { [accountNotifications] in await Self.removeAccountNotifications(from: accountNotifications) }
        #endif
    }

    static func endSchoolSession(departing studentId: String?) {
        MoodleEnrolledCoursesService.dropSharedAnswer()
        ClassroomUsageService.shared.forget()
        NTUSTSessionManager.shared.invalidateSession()
        CourseSelectionService.invalidateEnrolledCoursesCache(for: studentId)
    }

    func clearReauthError() {
        reauthErrorMessage = nil
    }

    #if os(iOS)
    static func removeAccountNotifications(from center: any DeliveredNotificationCenter) async {
        let identifiers = await center.deliveredNotificationThreads()
            .filter { $0.thread != MailConstants.notificationThread }
            .map(\.identifier)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
    #endif
}

#if os(iOS)
@MainActor
protocol DeliveredNotificationCenter {
    func deliveredNotificationThreads() async -> [(identifier: String, thread: String)]
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: DeliveredNotificationCenter {
    func deliveredNotificationThreads() async -> [(identifier: String, thread: String)] {
        await deliveredNotifications().map { ($0.request.identifier, $0.request.content.threadIdentifier) }
    }
}
#endif
