import Defaults
import Foundation
import os
import Testing
@testable import TigerDuck

/// School sign-ins against stand-ins: `SSOLoginService.ensureServiceLogin` against
/// `SSOServerStub`, and the Moodle token renewal with a stub harvest. Serialized: the SSO probe
/// asks one fixed URL, the stub's queues are shared, and so is the stored-password latch.
@MainActor
@Suite(.serialized)
struct SSOServiceLoginTests {
    typealias Pages = SSOPageFixtures

    static let probeURL = URL(string: "https://ssoam2.ntust.edu.tw/")!
    static let loginURL = URL(
        string: "https://ssoam2.ntust.edu.tw/account/login?ReturnUrl=%2Fconnect%2Fauthorize%3Fclient_id%3Dstub"
    )!
    /// Where the fixture form posts, resolved against ``loginURL``.
    static let postURL = URL(
        string: "https://ssoam2.ntust.edu.tw/account/login?ReturnUrl=%2Fconnect%2Fauthorize%2Fcallback"
    )!
    static let servicePage = "<html><body><table><tr><td>CS1001301</td></tr></table></body></html>"
    private static let notSignedIn = SSOServerStub.Answer.redirect(to: "/account/login?ReturnUrl=%2F")

    static func serviceURL() -> URL {
        URL(string: "https://service.stub.invalid/\(UUID().uuidString)/")!
    }

    /// The service sends this visit to the ssoam2 sign-in form.
    static func enqueueSignInForm(for service: URL) {
        SSOServerStub.enqueue(.follow(to: loginURL), for: service)
        SSOServerStub.enqueue(.page(Pages.ssoam2Login), for: loginURL)
    }

    struct Outcome {
        let result: Result<Bool, Error>
        /// `SSOLoginService.storedPasswordRejected` when the sign-in ended.
        let rejected: Bool
    }

    /// Runs `body` with the latch set to `rejected`, then puts the latch and the login stamp back.
    /// Both are real `Defaults` keys, which `BackendSessionTests` reads too.
    func withLatch<T>(_ rejected: Bool, _ body: () async -> T) async -> T {
        await withExclusiveRealDefaults {
            let saved = (SSOLoginService.storedPasswordRejected, Defaults[.ssoLoginTimestamp])
            SSOLoginService.storedPasswordRejected = rejected
            defer { (SSOLoginService.storedPasswordRejected, Defaults[.ssoLoginTimestamp]) = saved }
            return await body()
        }
    }

    func signIn(
        _ serviceURL: URL,
        interactive: Bool = false,
        rejectedBefore: Bool = false,
        setUp: () -> Void
    ) async -> Outcome {
        SSOServerStub.reset()
        setUp()
        return await withLatch(rejectedBefore) {
            let result: Result<Bool, Error>
            do {
                result = .success(try await SSOLoginService.ensureServiceLogin(
                    session: SSOServerStub.session(),
                    serviceURL: serviceURL,
                    studentId: "B00000000",
                    password: "unused",
                    generation: NTUSTSessionManager.shared.generation,
                    interactive: interactive
                ))
            } catch {
                result = .failure(error)
            }
            return Outcome(result: result, rejected: SSOLoginService.storedPasswordRejected)
        }
    }

    var posts: [SSOServerStub.Request] {
        SSOServerStub.requests.filter { $0.method == "POST" }
    }

    // MARK: - What counts as signed in

    @Test("a maintenance page without a live SSO session is not a sign-in")
    func maintenancePageIsNoSignIn() async {
        let service = Self.serviceURL()
        let outcome = await signIn(service) {
            SSOServerStub.enqueue(.page(Pages.maintenance, status: 503), for: service)
            SSOServerStub.enqueue(.page(Pages.maintenance, status: 503), for: service)
            SSOServerStub.enqueue(Self.notSignedIn, for: Self.probeURL)
            SSOServerStub.enqueue(Self.notSignedIn, for: Self.probeURL)
        }
        guard case .failure(SSOLoginError.loginFormNotFound) = outcome.result else {
            Issue.record("expected loginFormNotFound, got \(outcome.result)")
            return
        }
        #expect(posts.isEmpty)
        #expect(SSOServerStub.requests.filter { $0.url == service }.count == 2)
        #expect(!outcome.rejected)
    }

    @Test("ssoam's NetIQ form asks for a browser sign-in")
    func netIQFormNeedsABrowser() async {
        let service = Self.serviceURL()
        let outcome = await signIn(service) {
            SSOServerStub.enqueue(.follow(to: Pages.netIQLoginURL), for: service)
            SSOServerStub.enqueue(.page(Pages.netIQLogin), for: Pages.netIQLoginURL)
        }
        guard case .failure(SSOLoginError.interactiveLoginRequired) = outcome.result else {
            Issue.record("expected interactiveLoginRequired, got \(outcome.result)")
            return
        }
        #expect(SSOServerStub.requests.map(\.url) == [service, Pages.netIQLoginURL])
    }

    @Test("a service page with a live SSO session signs in without posting")
    func liveSessionSignsIn() async {
        let service = Self.serviceURL()
        let outcome = await signIn(service) {
            SSOServerStub.enqueue(.page(Self.servicePage), for: service)
            SSOServerStub.enqueue(.redirect(to: "/Home/Index"), for: Self.probeURL)
        }
        guard case .success(true) = outcome.result else {
            Issue.record("expected a sign-in, got \(outcome.result)")
            return
        }
        #expect(posts.isEmpty)
    }

    /// The session may be the stored account's, but the password is the one just typed, which the
    /// school checks only on the form (https://github.com/tigerduck-app/tigerduck-app/issues/412).
    @Test("a sign-in the user starts on a live session still posts the typed password")
    func interactiveSignInOnALiveSessionPostsThePassword() async {
        let service = Self.serviceURL()
        let outcome = await signIn(service, interactive: true) {
            SSOServerStub.enqueue(.page(Self.servicePage), for: service)
            Self.enqueueSignInForm(for: service)
            SSOServerStub.enqueue(.page(Self.servicePage), for: Self.postURL)
            SSOServerStub.enqueue(.redirect(to: "/Home/Index"), for: Self.probeURL)
        }
        guard case .success(true) = outcome.result else {
            Issue.record("expected a sign-in, got \(outcome.result)")
            return
        }
        #expect(posts.map(\.url) == [Self.postURL])
        #expect(posts.first?.body.contains("Password=unused") == true)
    }

    @Test("a mistyped password in a sign-in the user starts on a live session is refused")
    func interactiveSignInOnALiveSessionRefusesAMistypedPassword() async {
        let service = Self.serviceURL()
        let outcome = await signIn(service, interactive: true) {
            SSOServerStub.enqueue(.page(Self.servicePage), for: service)
            SSOServerStub.enqueue(.redirect(to: "/Home/Index"), for: Self.probeURL)
            Self.enqueueSignInForm(for: service)
            SSOServerStub.enqueue(.page(Pages.ssoam2LoginRejected), for: Self.postURL)
        }
        guard case .failure(SSOLoginError.loginFailed) = outcome.result else {
            Issue.record("expected loginFailed, got \(outcome.result)")
            return
        }
        #expect(posts.count == 1)
        #expect(!outcome.rejected)
    }

    @Test("a visit sent to the campus portal reaches the sign-in form once the service's cookies are gone")
    func portalVisitSignsInThroughTheForm() async {
        let service = Self.serviceURL()
        let portal = "<html><body><h1>臺科大校園入口</h1><a href=\"/login\">登入</a></body></html>"
        let outcome = await signIn(service) {
            SSOServerStub.enqueue(.page(portal), for: service)
            SSOServerStub.enqueue(Self.notSignedIn, for: Self.probeURL)
            Self.enqueueSignInForm(for: service)
            Self.enqueueSignInForm(for: service)
            SSOServerStub.enqueue(.page(Self.servicePage), for: Self.postURL)
            SSOServerStub.enqueue(.redirect(to: "/Home/Index"), for: Self.probeURL)
        }
        guard case .success(true) = outcome.result else {
            Issue.record("expected a sign-in, got \(outcome.result)")
            return
        }
        #expect(posts.map(\.url) == [Self.postURL])
        #expect(posts.first?.body.contains("Username=B00000000") == true)
    }

    @Test("a password POST answered with an error page and no live session is not a sign-in")
    func errorPageAfterThePostIsNoSignIn() async {
        let service = Self.serviceURL()
        let outcome = await signIn(service, interactive: true) {
            Self.enqueueSignInForm(for: service)
            Self.enqueueSignInForm(for: service)
            SSOServerStub.enqueue(.page(Pages.maintenance, status: 500), for: Self.postURL)
            SSOServerStub.enqueue(Self.notSignedIn, for: Self.probeURL)
        }
        guard case .failure(SSOLoginError.invalidResponse) = outcome.result else {
            Issue.record("expected invalidResponse, got \(outcome.result)")
            return
        }
        #expect(!outcome.rejected)
    }

    // MARK: - A rejected stored password

    @Test("a sign-in the user did not start posts no password the school rejected")
    func rejectedPasswordIsNotPostedAgain() async {
        let service = Self.serviceURL()
        let outcome = await signIn(service, rejectedBefore: true) {
            Self.enqueueSignInForm(for: service)
        }
        guard case .failure(SSOLoginError.loginFailed) = outcome.result else {
            Issue.record("expected loginFailed, got \(outcome.result)")
            return
        }
        #expect(SSOServerStub.requests.map(\.url) == [service, Self.loginURL])
        #expect(outcome.rejected)
    }

    @Test("a rejection in a sign-in the user did not start stops the next ones")
    func silentRejectionLatches() async {
        let service = Self.serviceURL()
        let outcome = await signIn(service) {
            Self.enqueueSignInForm(for: service)
            Self.enqueueSignInForm(for: service)
            SSOServerStub.enqueue(.page(Pages.ssoam2Login), for: Self.postURL)
        }
        guard case .failure(SSOLoginError.loginFailed) = outcome.result else {
            Issue.record("expected loginFailed, got \(outcome.result)")
            return
        }
        #expect(posts.count == 1)
        #expect(outcome.rejected)
    }

    @Test("a sign-in the user starts posts after a rejection and lifts it")
    func interactiveSignInLiftsTheLatch() async {
        let service = Self.serviceURL()
        let outcome = await signIn(service, interactive: true, rejectedBefore: true) {
            Self.enqueueSignInForm(for: service)
            Self.enqueueSignInForm(for: service)
            SSOServerStub.enqueue(.page(Self.servicePage), for: Self.postURL)
            SSOServerStub.enqueue(.redirect(to: "/Home/Index"), for: Self.probeURL)
        }
        guard case .success(true) = outcome.result else {
            Issue.record("expected a sign-in, got \(outcome.result)")
            return
        }
        #expect(posts.count == 1)
        #expect(!outcome.rejected)
    }

    @Test("a rejected password fails with the school's reason, shown in the sign-in's message")
    func rejectionCarriesTheSchoolsReason() async {
        let service = Self.serviceURL()
        let outcome = await signIn(service, interactive: true) {
            Self.enqueueSignInForm(for: service)
            Self.enqueueSignInForm(for: service)
            SSOServerStub.enqueue(.page(Pages.ssoam2LoginRejected), for: Self.postURL)
        }
        guard case .failure(SSOLoginError.loginFailed(let reason)) = outcome.result else {
            Issue.record("expected loginFailed, got \(outcome.result)")
            return
        }
        #expect(reason == "帳號或密碼錯誤")
        #expect(SSOLoginError.loginFailed(reason: reason).localizedDescription
            == String(format: String(localized: "error_sso_sign_in_failed_with_reason"), "帳號或密碼錯誤"))
    }

    @Test("a rejection without a message on the page keeps the generic message")
    func rejectionWithoutAReasonKeepsTheGenericMessage() async {
        let service = Self.serviceURL()
        let outcome = await signIn(service, interactive: true) {
            Self.enqueueSignInForm(for: service)
            Self.enqueueSignInForm(for: service)
            SSOServerStub.enqueue(.page(Pages.ssoam2Login), for: Self.postURL)
        }
        guard case .failure(SSOLoginError.loginFailed(let reason)) = outcome.result else {
            Issue.record("expected loginFailed, got \(outcome.result)")
            return
        }
        #expect(reason == nil)
        let generic = String(localized: "error_sso_sign_in_failed")
        #expect(SSOLoginError.loginFailed(reason: nil).localizedDescription == generic)
        #expect(SSOLoginError.loginFailed(reason: "").localizedDescription == generic)
    }

    @Test("a mistyped password in a sign-in the user starts sets no latch")
    func interactiveRejectionDoesNotLatch() async {
        let service = Self.serviceURL()
        let outcome = await signIn(service, interactive: true) {
            Self.enqueueSignInForm(for: service)
            Self.enqueueSignInForm(for: service)
            SSOServerStub.enqueue(.page(Pages.ssoam2Login), for: Self.postURL)
        }
        guard case .failure(SSOLoginError.loginFailed) = outcome.result else {
            Issue.record("expected loginFailed, got \(outcome.result)")
            return
        }
        #expect(!outcome.rejected)
    }

    @MainActor
    private final class FailureLog {
        var errors: [any Error] = []
    }

    /// Leaving a screen or signing out ends a sign-in's request; the device log keeps real
    /// failures only (https://github.com/tigerduck-app/tigerduck-app/issues/584).
    @Test("a sign-in a cancelled request ends leaves nothing in the log, and a failed one is logged")
    func cancelledSignInIsNotLogged() async {
        let cancelled = Self.serviceURL()
        let failed = Self.serviceURL()
        SSOServerStub.reset()
        SSOServerStub.enqueue(.failure(.cancelled), for: cancelled)
        SSOServerStub.enqueue(.failure(.timedOut), for: failed)
        let log = FailureLog()
        func loggedSignIn(_ service: URL) async -> Result<Bool, Error> {
            await Self.result {
                try await SSOLoginService.ensureServiceLogin(
                    session: SSOServerStub.session(), serviceURL: service, studentId: "B00000000",
                    password: "unused", generation: NTUSTSessionManager.shared.generation,
                    logFailure: { log.errors.append($0) }
                )
            }
        }

        let ended = await withLatch(false) { await loggedSignIn(cancelled) }
        #expect(log.errors.isEmpty)
        let timedOut = await withLatch(false) { await loggedSignIn(failed) }

        guard case .failure(let endedError) = ended, case .failure = timedOut else {
            Issue.record("expected two failures, got \(ended) and \(timedOut)")
            return
        }
        #expect(AppLogger.isCancellation(endedError))
        #expect(log.errors.map { ($0 as? URLError)?.code } == [.timedOut])
        #expect(AppLogger.isCancellation(CancellationError()))
    }

    // MARK: - Moodle token renewal

    actor HarvestLog {
        private(set) var calls = 0
        func record() { calls += 1 }
    }

    /// The keychain password a stand-in token service reads; a harvest can change it meanwhile.
    private final class StoredPassword: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String

        init(_ value: String) { self.value = value }

        var current: String {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    /// A harvest without `failure` hands out the token "new". `token` stands in for the keychain.
    private func tokenService(
        log: HarvestLog,
        failure: MoodleWebserviceError?,
        stored: StoredPassword = StoredPassword("unused"),
        token: OSAllocatedUnfairLock<String?> = OSAllocatedUnfairLock(initialState: nil),
        now: @escaping @Sendable () -> Date = { Date() },
        duringHarvest: @escaping @Sendable () async -> Void = {}
    ) -> MoodleTokenService {
        MoodleTokenService(
            storedCredentials: { (studentId: "b00000000", password: stored.current) },
            tokens: MoodleTokenService.TokenStore(
                load: { token.withLock { $0 } },
                save: { triple in token.withLock { $0 = triple.wstoken } },
                drop: { token.withLock { $0 = nil } }
            ),
            harvest: { _, _ in
                await log.record()
                await duringHarvest()
                if let failure { throw failure }
                return MoodleTokenService.TokenTriple(signature: "", wstoken: "new", privatetoken: nil)
            },
            now: now
        )
    }

    @Test("a renewal the school rejected stops the next one")
    func rejectedRenewalLatches() async {
        let log = HarvestLog()
        let service = tokenService(log: log, failure: .ssoLoginRejected(reason: "帳號或密碼錯誤"))
        let rejected = await withLatch(false) {
            await #expect(throws: MoodleWebserviceError.ssoLoginRejected(reason: "帳號或密碼錯誤")) {
                try await service.refreshTokenIfNeeded()
            }
            await #expect(throws: MoodleWebserviceError.ssoLoginRejected(reason: nil)) {
                try await service.refreshTokenIfNeeded()
            }
            return SSOLoginService.storedPasswordRejected
        }
        #expect(rejected)
        #expect(await log.calls == 1)
    }

    @Test("a renewal that ran on a password replaced meanwhile sets no latch")
    func renewalOnAReplacedPasswordDoesNotLatch() async {
        let log = HarvestLog()
        let stored = StoredPassword("old")
        let service = tokenService(log: log, failure: .ssoLoginRejected(reason: nil), stored: stored) {
            stored.current = "new"
        }
        let rejected = await withLatch(false) {
            await #expect(throws: MoodleWebserviceError.ssoLoginRejected(reason: nil)) {
                try await service.refreshTokenIfNeeded()
            }
            return SSOLoginService.storedPasswordRejected
        }
        #expect(!rejected)
    }

    /// Each Moodle page that appears without a token asks for one, and each harvest sends the
    /// password.
    @Test("a renewal that fails for another reason sets no latch, and the next waits out a pause")
    func otherRenewalFailuresPause() async {
        let log = HarvestLog()
        let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_000_000))
        let service = tokenService(log: log, failure: .httpStatus(code: 503), now: { clock.withLock { $0 } })
        let rejected = await withLatch(false) {
            for _ in 0..<2 {
                await #expect(throws: MoodleWebserviceError.httpStatus(code: 503)) {
                    try await service.refreshTokenIfNeeded()
                }
            }
            #expect(await log.calls == 1)
            clock.withLock { $0 += MoodleTokenService.harvestPause }
            _ = try? await service.refreshTokenIfNeeded()
            return SSOLoginService.storedPasswordRejected
        }
        #expect(!rejected)
        #expect(await log.calls == 2)
    }

    @Test("a renewal that failed on the network starts no pause")
    func networkFailureStartsNoPause() async {
        let log = HarvestLog()
        let service = tokenService(log: log, failure: .transientNetwork(underlying: "offline"))
        _ = await withLatch(false) {
            for _ in 0..<2 { _ = try? await service.refreshTokenIfNeeded() }
        }
        #expect(await log.calls == 2)
    }

    @Test("a sign-out ends the pause a failed renewal started")
    func signOutEndsThePause() async {
        let log = HarvestLog()
        let service = tokenService(log: log, failure: .httpStatus(code: 503))
        _ = await withLatch(false) {
            _ = try? await service.refreshTokenIfNeeded()
            await service.signOut()
            _ = try? await service.refreshTokenIfNeeded()
        }
        #expect(await log.calls == 2)
    }

    @Test("a renewal still running is shared, and a later one gets its result")
    func renewalServesEveryCallerThatMetTheOldToken() async {
        let log = HarvestLog()
        let token = OSAllocatedUnfairLock<String?>(initialState: "old")
        let released = OSAllocatedUnfairLock(initialState: false)
        let service = tokenService(log: log, failure: nil, token: token) {
            while !released.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(5)) }
        }
        let answers = await withLatch(false) { () async -> [String?] in
            async let first = try? service.refreshTokenIfNeeded(replacing: "old")
            while await log.calls == 0 { try? await Task.sleep(for: .milliseconds(5)) }
            // The held harvest has dropped the old token, so a second call that did not join it
            // would harvest again.
            async let second = try? service.refreshTokenIfNeeded(replacing: "old")
            try? await Task.sleep(for: .milliseconds(100))
            released.withLock { $0 = true }
            let together = await [first, second]
            return together + [try? await service.refreshTokenIfNeeded(replacing: "old")]
        }
        #expect(answers == ["new", "new", "new"])
        #expect(token.withLock { $0 } == "new")
        #expect(await log.calls == 1)
    }

    /// A harvest holds the stored-password lock, so a server that trickles its answer would hold
    /// every automatic SSO sign-in behind it for the default week.
    @Test("a harvest gives up on a server that trickles its answer after a minute")
    func harvestTimesOut() {
        let config = MoodleTokenService.harvestConfiguration()
        #expect(config.timeoutIntervalForResource == 60)
        #expect(config.timeoutIntervalForRequest == 20)
        #expect(config.httpCookieStorage === HTTPCookieStorage.shared)
    }

    /// Each request stops after a minute, but a harvest makes up to seven in turn while every
    /// automatic sign-in waits for the lock it holds
    /// (https://github.com/tigerduck-app/tigerduck-app/issues/607).
    @Test("a harvest past its deadline fails as a request timeout does")
    func aHarvestPastItsDeadlineFails() async {
        let service = MoodleTokenService(
            storedCredentials: { (studentId: "b00000000", password: "unused") },
            tokens: MoodleTokenService.TokenStore(load: { nil }, save: { _ in }, drop: {}),
            harvest: { _, _ in
                try await Task.sleep(for: .seconds(5))
                return MoodleTokenService.TokenTriple(signature: "", wstoken: "late", privatetoken: nil)
            },
            harvestDeadline: .milliseconds(100)
        )
        _ = await withLatch(false) {
            let started = ContinuousClock.now
            await #expect(throws: MoodleWebserviceError.transientNetwork(underlying: URLError(.timedOut).localizedDescription)) {
                try await service.refreshTokenIfNeeded()
            }
            #expect(ContinuousClock.now - started < .seconds(3))
        }
    }

    @Test("a failed renewal leaves no rejected token behind")
    func failedRenewalDropsTheRejectedToken() async {
        let log = HarvestLog()
        let token = OSAllocatedUnfairLock<String?>(initialState: "old")
        let service = tokenService(log: log, failure: .transientNetwork(underlying: "offline"), token: token)
        _ = await withLatch(false) {
            await #expect(throws: MoodleWebserviceError.transientNetwork(underlying: "offline")) {
                try await service.refreshTokenIfNeeded(replacing: "old")
            }
        }
        #expect(token.withLock { $0 } == nil)
        #expect(await log.calls == 1)
    }

    // MARK: - One automatic post of the stored password at a time
    // https://github.com/tigerduck-app/tigerduck-app/issues/574

    static func result<T>(_ body: () async throws -> T) async -> Result<T, Error> {
        do {
            return .success(try await body())
        } catch {
            return .failure(error)
        }
    }

    private static func waitForAQueuedPost() async {
        while await SSOLoginService.storedPasswordPostsWaiting() == 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func automaticSignIn(_ serviceURL: URL) async -> Result<Bool, Error> {
        await Self.result {
            try await SSOLoginService.ensureServiceLogin(
                session: SSOServerStub.session(),
                serviceURL: serviceURL,
                studentId: "B00000000",
                password: "unused",
                generation: NTUSTSessionManager.shared.generation
            )
        }
    }

    /// After a password change elsewhere, a cold start whose Moodle token is also dead runs both;
    /// each post of the old password counts toward the account's lockout.
    @Test("an automatic sign-in waits while a renewal posts the stored password, and posts none once it is refused")
    func automaticSignInWaitsForARenewalsPost() async {
        let service = Self.serviceURL()
        SSOServerStub.reset()
        Self.enqueueSignInForm(for: service)
        Self.enqueueSignInForm(for: service)
        SSOServerStub.enqueue(.page(Pages.ssoam2Login), for: Self.postURL)
        let log = HarvestLog()
        let answered = OSAllocatedUnfairLock(initialState: false)
        let renewal = tokenService(log: log, failure: .ssoLoginRejected(reason: nil), duringHarvest: {
            while !answered.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(5)) }
        })
        let (signIn, rejected) = await withLatch(false) { () async -> (Result<Bool, Error>, Bool) in
            async let renewing = try? renewal.refreshTokenIfNeeded()
            while await log.calls == 0 { try? await Task.sleep(for: .milliseconds(5)) }
            async let signingIn = automaticSignIn(service)
            // Long enough for a sign-in that does not wait to reach its POST.
            for _ in 0..<100 where posts.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
            answered.withLock { $0 = true }
            _ = await renewing
            return (await signingIn, SSOLoginService.storedPasswordRejected)
        }
        guard case .failure(SSOLoginError.loginFailed) = signIn else {
            Issue.record("expected loginFailed, got \(signIn)")
            return
        }
        #expect(posts.isEmpty)
        #expect(await log.calls == 1)
        #expect(rejected)
    }

    @Test("a renewal waits while an automatic sign-in posts the stored password, and harvests nothing once it is refused", .timeLimit(.minutes(1)))
    func renewalWaitsForAnAutomaticSignInsPost() async {
        let log = HarvestLog()
        let renewal = tokenService(log: log, failure: nil)
        let (outcome, harvests) = await withLatch(false) { () async -> (Result<String, Error>, Int) in
            // The test holds the lock as an automatic sign-in does while the school answers its post.
            let renewing = await SSOLoginService.postingStoredPassword {
                let renewing = Task { await Self.result { try await renewal.refreshTokenIfNeeded() } }
                // Queued for the lock, so past its first check of the latch.
                await Self.waitForAQueuedPost()
                SSOLoginService.storedPasswordRejected = true
                return renewing
            }
            return (await renewing.value, await log.calls)
        }
        guard case .failure(MoodleWebserviceError.ssoLoginRejected) = outcome else {
            Issue.record("expected ssoLoginRejected, got \(outcome)")
            return
        }
        #expect(harvests == 0)
    }

    /// The stored account may be the next student's by the time the lock comes free.
    @Test("a renewal that a sign-out overtook while it waited for the lock harvests nothing", .timeLimit(.minutes(1)))
    func renewalASignOutOvertookHarvestsNothing() async {
        let log = HarvestLog()
        let renewal = tokenService(log: log, failure: nil)
        let (outcome, harvests) = await withLatch(false) { () async -> (Result<String, Error>, Int) in
            let renewing = await SSOLoginService.postingStoredPassword {
                let renewing = Task { await Self.result { try await renewal.refreshTokenIfNeeded() } }
                await Self.waitForAQueuedPost()
                await renewal.signOut()
                return renewing
            }
            return (await renewing.value, await log.calls)
        }
        guard case .failure = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(harvests == 0)
    }

    /// A sign-in the user typed posts what was typed, so it goes ahead while an automatic post of
    /// the stored password holds the lock. Waiting would hang, hence the time limit.
    @Test("a sign-in the user typed does not wait for an automatic post of the stored password", .timeLimit(.minutes(1)))
    func typedSignInsDoNotWaitForTheStoredPasswordsPosts() async {
        let service = Self.serviceURL()
        SSOServerStub.reset()
        Self.enqueueSignInForm(for: service)
        Self.enqueueSignInForm(for: service)
        SSOServerStub.enqueue(.page(Self.servicePage), for: Self.postURL)
        SSOServerStub.enqueue(.redirect(to: "/Home/Index"), for: Self.probeURL)
        let log = HarvestLog()
        let tokens = tokenService(log: log, failure: nil)
        let (signedIn, token) = await withLatch(false) { () async -> (Result<Bool, Error>, String?) in
            await SSOLoginService.postingStoredPassword {
                let signedIn = await Self.result {
                    try await SSOLoginService.ensureServiceLogin(
                        session: SSOServerStub.session(),
                        serviceURL: service,
                        studentId: "B00000000",
                        password: "typed",
                        generation: NTUSTSessionManager.shared.generation,
                        interactive: true
                    )
                }
                return (signedIn, try? await tokens.obtainToken(studentId: "B00000000", password: "typed"))
            }
        }
        guard case .success(true) = signedIn else {
            Issue.record("expected a sign-in, got \(signedIn)")
            return
        }
        #expect(token == "new")
    }

    // MARK: - What a renewal latches (https://github.com/tigerduck-app/tigerduck-app/issues/575)

    /// A renewal whose harvest walks the school's pages from `page` at `url`, against `SSOServerStub`.
    func pageWalk(log: HarvestLog, from page: String, at url: URL) -> MoodleTokenService {
        MoodleTokenService(
            storedCredentials: { (studentId: "b00000000", password: "unused") },
            tokens: .init(load: { nil }, save: { _ in }, drop: {}),
            harvest: { studentId, password in
                await log.record()
                return try await MoodleTokenService.resolveTokenTriple(
                    session: SSOServerStub.session(),
                    data: Data(page.utf8),
                    responseURL: url,
                    studentId: studentId,
                    password: password,
                    remainingSteps: 6
                )
            }
        )
    }

    /// A maintenance or error page served at the sign-in path has no form, so no password went out.
    @Test("a sign-in page without its form pauses the renewal and sets no latch")
    func signInPageWithoutItsFormSetsNoLatch() async {
        SSOServerStub.reset()
        let log = HarvestLog()
        let renewal = pageWalk(log: log, from: Pages.maintenance, at: Self.loginURL)
        let (first, rejected) = await withLatch(false) { () async -> (Result<String, Error>, Bool) in
            let first = await Self.result { try await renewal.refreshTokenIfNeeded() }
            _ = try? await renewal.refreshTokenIfNeeded()
            return (first, SSOLoginService.storedPasswordRejected)
        }
        guard case .failure(MoodleWebserviceError.malformedResponse) = first else {
            Issue.record("expected malformedResponse, got \(first)")
            return
        }
        #expect(!rejected)
        #expect(posts.isEmpty)
        // Paused as other failures are: the second renewal sent nothing.
        #expect(await log.calls == 1)
    }

    @Test("the school's refusal of a password the renewal posted still latches")
    func refusalOfAPostedPasswordLatches() async {
        SSOServerStub.reset()
        SSOServerStub.enqueue(.page(Pages.ssoam2LoginRejected), for: Self.postURL)
        let log = HarvestLog()
        let renewal = pageWalk(log: log, from: Pages.ssoam2Login, at: Self.loginURL)
        let (outcome, rejected) = await withLatch(false) { () async -> (Result<String, Error>, Bool) in
            (await Self.result { try await renewal.refreshTokenIfNeeded() }, SSOLoginService.storedPasswordRejected)
        }
        guard case .failure(MoodleWebserviceError.ssoLoginRejected(let reason)) = outcome else {
            Issue.record("expected ssoLoginRejected, got \(outcome)")
            return
        }
        #expect(reason == "帳號或密碼錯誤")
        #expect(rejected)
        #expect(posts.map(\.url) == [Self.postURL])
    }
}
