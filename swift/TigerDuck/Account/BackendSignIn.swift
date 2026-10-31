import Foundation
import os

/// Signs the stored account in to the TigerDuck backend with its Moodle token: after a school
/// sign-in, when the app returns without a backend session, and when the backend refuses a
/// refresh. One sign-in runs at a time.
@MainActor
@Observable
final class BackendSignIn {
    private(set) var isSigningIn = false
    @ObservationIgnored private var running: Task<Void, Never>?
    /// When an automatic backend sign-in that had credentials to send last failed. The backend
    /// takes five logins per student and per IP in 15 minutes (`auth_login_max_attempts` in
    /// https://github.com/tigerduck-app/tigerduck-backend/blob/main/server/config.py), and a
    /// campus network puts many students behind one IP, so the next automatic one waits ``pause``.
    @ObservationIgnored private var failedAt: Date?
    @ObservationIgnored private weak var auth: AuthService?

    nonisolated static let pause: TimeInterval = 5 * 60

    init(auth: AuthService) {
        self.auth = auth
    }

    nonisolated static func isDue(lastFailure: Date?, now: Date) -> Bool {
        guard let lastFailure else { return true }
        let age = now.timeIntervalSince(lastFailure)
        return age >= pause || age < 0
    }

    @discardableResult
    func signIn(studentId: String, harvesting: Bool = false) async -> Bool {
        guard let auth else { return false }
        guard let authTokenManager = auth.authTokenManager else { return false }
        let session = auth.session
        let ticket = session.ticket
        await auth.departingUnregisterRetry?.value
        let moodleToken = harvesting ? await moodleToken() : await auth.deps.moodleTokens.currentToken()
        guard let moodleToken, !moodleToken.isEmpty, session.isCurrent(ticket) else { return false }
        do {
            _ = try await authTokenManager.login(
                studentId: studentId,
                moodleToken: moodleToken,
                moodlePrivateToken: KeychainManager.loadString(key: AppConstants.KeychainKeys.moodlePrivateToken),
                platform: PushDeviceClass.platform(for: PushDeviceClass.resolvedForBuild)
            )
            guard session.isCurrent(ticket) else { return false }
            failedAt = nil
            auth.onV3SignedIn?()
            return true
        } catch {
            guard session.isCurrent(ticket) else { return false }
            AppLogger.captureError(error, context: ["flow": "v3Login"])
            return false
        }
    }

    func relogin(replacing refused: String?) async -> Bool {
        guard let auth else { return false }
        guard let authTokenManager = auth.authTokenManager,
              Self.isDue(lastFailure: failedAt, now: Date()),
              let studentId = auth.storedStudentId else { return false }
        let ticket = auth.session.ticket
        guard let moodleToken = await moodleToken(), auth.session.isCurrent(ticket) else {
            AppLogger.sync.info("auto-relogin skipped: no Moodle token")
            noteFailure(since: ticket)
            return false
        }
        do {
            let result = try await authTokenManager.login(
                studentId: studentId,
                moodleToken: moodleToken,
                moodlePrivateToken: KeychainManager.loadString(key: AppConstants.KeychainKeys.moodlePrivateToken),
                platform: PushDeviceClass.platform(for: PushDeviceClass.resolvedForBuild),
                replacing: refused
            )
            AppLogger.sync.info("auto-relogin: \(result == nil ? "newer session kept" : "v3 JWT refreshed", privacy: .public)")
            failedAt = nil
            return true
        } catch {
            AppLogger.sync.error("auto-relogin failed: \(error, privacy: .private)")
            noteFailure(since: ticket)
            return false
        }
    }

    func ensureSignedIn() async {
        if let running { return await running.value }
        let task = Task { await signInIfSignedOut() }
        running = task
        await task.value
        if running == task { running = nil }
    }

    /// Waits out a sign-in under way, then signs in without the pause a failure set.
    func signInAgain() async {
        if let current = running {
            await current.value
            if running == current { running = nil }
        }
        failedAt = nil
        await ensureSignedIn()
    }

    func reset() {
        running?.cancel()
        running = nil
        failedAt = nil
    }

    private func signInIfSignedOut() async {
        guard let auth else { return }
        guard let atm = auth.authTokenManager, !(await atm.isLoggedIn),
              Self.isDue(lastFailure: failedAt, now: Date()),
              let studentId = auth.storedStudentId, auth.storedPassword != nil else { return }
        let ticket = auth.session.ticket
        isSigningIn = true
        defer { isSigningIn = false }
        if await !signIn(studentId: studentId, harvesting: true) {
            noteFailure(since: ticket)
        }
    }

    private func noteFailure(since ticket: AccountSession.Ticket) {
        guard let auth else { return }
        guard auth.session.isCurrent(ticket) else { return }
        failedAt = Date()
    }

    private func moodleToken() async -> String? {
        guard let auth else { return nil }
        do {
            let token = try await auth.deps.moodleTokens.refreshTokenIfNeeded()
            return token.isEmpty ? nil : token
        } catch {
            let line = AppLogger.errorLine(error, context: [:])
            AppLogger.auth.info("no Moodle token for the backend: \(line, privacy: .private)")
            return nil
        }
    }
}

/// Tries the stored password again once the school stops refusing it, after the wait
/// `SSOLoginService` sets, and backs off further when a try finds the school still refusing.
@MainActor
final class StoredPasswordRetry {
    private(set) var task: Task<Void, Never>?
    private var misses = 0
    private weak var auth: AuthService?

    init(auth: AuthService) {
        self.auth = auth
    }

    func arm() {
        guard let auth else { return }
        misses = 0
        let now = auth.deps.now
        guard let retryAt = SchoolPasswordPosts.storedPasswordRetryAt(now: now()) else {
            cancel()
            return
        }
        start(after: max(0, retryAt.timeIntervalSince(now())))
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private func armAfterAMiss() {
        let refusals = SchoolPasswordPosts.storedPasswordRefusals.count
        guard refusals > 0 else { return }
        misses += 1
        start(after: StoredPasswordBackoff.retryDelay(afterRefusals: refusals + misses))
    }

    private func start(after wait: TimeInterval) {
        guard let auth else { return }
        task?.cancel()
        let sleep = auth.deps.retrySleep
        task = auth.session.task { [weak self] ticket in
            await sleep(.seconds(wait))
            guard !Task.isCancelled, let self, let auth = self.auth, auth.session.isCurrent(ticket) else { return }
            self.task = nil
            await self.retry()
        }
    }

    private func retry() async {
        guard let auth else { return }
        let now = auth.deps.now
        guard let retryAt = SchoolPasswordPosts.storedPasswordRetryAt(now: now()) else { return }
        guard retryAt <= now() else {
            arm()
            return
        }
        let refusals = SchoolPasswordPosts.storedPasswordRefusals.count
        guard await !run(), SchoolPasswordPosts.storedPasswordRefusals.count == refusals else { return }
        armAfterAMiss()
    }

    private func run() async -> Bool {
        guard let auth else { return false }
        guard !auth.isLoggingIn, let studentId = auth.storedStudentId, let password = auth.storedPassword else { return false }
        let session = auth.session
        let ticket = session.ticket
        // A sign-in typed while the retry waited for the SSO lock posts what was typed instead.
        let posted = try? await auth.deps.retrySchoolSignIn(studentId, password, session.currentCheck()) { !auth.isLoggingIn }
        guard posted == true else { return false }
        auth.noteSchoolSignInRenewed()
        guard session.isCurrent(ticket) else { return false }
        auth.clearReauthError()
        guard (try? await auth.deps.moodleTokens.refreshTokenIfNeeded()) != nil, session.isCurrent(ticket) else { return false }
        // Not at the school's yes: a refused Moodle token sign-in after it would count from one
        // again, and the password would go out every ten seconds. The backend takes no password.
        SchoolPasswordPosts.forgetStoredPasswordRefusals()
        await auth.backend.signInAgain()
        return true
    }
}
