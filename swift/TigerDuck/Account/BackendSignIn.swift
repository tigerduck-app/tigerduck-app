import Foundation
import os

@MainActor
@Observable
final class BackendSignIn {
    private(set) var isSigningIn = false
    @ObservationIgnored private var running: Task<Void, Never>?
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
    func signIn(studentId: String, harvesting: Bool = false, for signIn: SignIn) async -> Bool {
        guard let auth else { return false }
        guard let authTokenManager = auth.authTokenManager else { return false }
        await auth.departingUnregisterRetry?.value
        let moodleToken = harvesting ? await moodleToken() : await auth.deps.moodleTokens.currentToken()
        guard let moodleToken, !moodleToken.isEmpty, signIn.isCurrent else { return false }
        do {
            _ = try await authTokenManager.login(
                studentId: studentId,
                moodleToken: moodleToken,
                moodlePrivateToken: KeychainManager.loadString(key: AppConstants.KeychainKeys.moodlePrivateToken),
                platform: PushDeviceClass.platform(for: PushDeviceClass.resolvedForBuild),
                for: signIn
            )
            guard signIn.isCurrent else { return false }
            failedAt = nil
            auth.onV3SignedIn?()
            return true
        } catch {
            guard signIn.isCurrent else { return false }
            AppLogger.captureError(error, context: ["flow": "v3Login"])
            return false
        }
    }

    func relogin(replacing refused: String?, for signIn: SignIn) async -> Bool {
        guard let auth else { return false }
        guard let authTokenManager = auth.authTokenManager,
              Self.isDue(lastFailure: failedAt, now: Date()),
              let studentId = auth.storedStudentId else { return false }
        guard let moodleToken = await moodleToken(), signIn.isCurrent else {
            AppLogger.sync.info("auto-relogin skipped: no Moodle token")
            noteFailure(of: signIn)
            return false
        }
        do {
            let result = try await authTokenManager.login(
                studentId: studentId,
                moodleToken: moodleToken,
                moodlePrivateToken: KeychainManager.loadString(key: AppConstants.KeychainKeys.moodlePrivateToken),
                platform: PushDeviceClass.platform(for: PushDeviceClass.resolvedForBuild),
                for: signIn,
                replacing: refused
            )
            AppLogger.sync.info("auto-relogin: \(result == nil ? "newer session kept" : "v3 JWT refreshed", privacy: .public)")
            failedAt = nil
            return true
        } catch {
            AppLogger.sync.error("auto-relogin failed: \(error, privacy: .private)")
            noteFailure(of: signIn)
            return false
        }
    }

    func ensureSignedIn() async {
        if let running { return await running.value }
        guard let auth else { return }
        let task = auth.session.task { [weak self] signIn in await self?.signInIfSignedOut(signIn) }
        running = task
        await task.value
        if running == task { running = nil }
    }

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

    private func signInIfSignedOut(_ signIn: SignIn) async {
        guard let auth else { return }
        guard let atm = auth.authTokenManager, !(await atm.isLoggedIn),
              Self.isDue(lastFailure: failedAt, now: Date()),
              let studentId = auth.storedStudentId, auth.storedPassword != nil else { return }
        isSigningIn = true
        defer { isSigningIn = false }
        if await !self.signIn(studentId: studentId, harvesting: true, for: signIn) {
            noteFailure(of: signIn)
        }
    }

    private func noteFailure(of signIn: SignIn) {
        guard signIn.isCurrent else { return }
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
        task = auth.session.task { [weak self] signIn in
            await sleep(.seconds(wait))
            guard !Task.isCancelled, let self, signIn.isCurrent else { return }
            self.task = nil
            await self.retry(signIn)
        }
    }

    private func retry(_ signIn: SignIn) async {
        guard let auth else { return }
        let now = auth.deps.now
        guard let retryAt = SchoolPasswordPosts.storedPasswordRetryAt(now: now()) else { return }
        guard retryAt <= now() else {
            arm()
            return
        }
        let refusals = SchoolPasswordPosts.storedPasswordRefusals.count
        guard await !run(signIn), SchoolPasswordPosts.storedPasswordRefusals.count == refusals else { return }
        armAfterAMiss()
    }

    private func run(_ signIn: SignIn) async -> Bool {
        guard let auth else { return false }
        guard !auth.isLoggingIn, let studentId = auth.storedStudentId, let password = auth.storedPassword else { return false }
        let mayPost = { !auth.isLoggingIn }
        let posted = try? await auth.deps.retrySchoolSignIn(studentId, password, signIn, mayPost)
        guard posted == true else { return false }
        auth.noteSchoolSignInRenewed()
        guard signIn.isCurrent else { return false }
        auth.clearReauthError()
        guard (try? await auth.deps.moodleTokens.refreshTokenIfNeeded()) != nil, signIn.isCurrent else { return false }
        SchoolPasswordPosts.forgetStoredPasswordRefusals()
        await auth.backend.signInAgain()
        return true
    }
}
