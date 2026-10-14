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
    private typealias Pages = SSOPageFixtures

    private static let probeURL = URL(string: "https://ssoam2.ntust.edu.tw/")!
    private static let loginURL = URL(
        string: "https://ssoam2.ntust.edu.tw/account/login?ReturnUrl=%2Fconnect%2Fauthorize%3Fclient_id%3Dstub"
    )!
    /// Where the fixture form posts, resolved against ``loginURL``.
    private static let postURL = URL(
        string: "https://ssoam2.ntust.edu.tw/account/login?ReturnUrl=%2Fconnect%2Fauthorize%2Fcallback"
    )!
    private static let servicePage = "<html><body><table><tr><td>CS1001301</td></tr></table></body></html>"
    private static let notSignedIn = SSOServerStub.Answer.redirect(to: "/account/login?ReturnUrl=%2F")

    private static func serviceURL() -> URL {
        URL(string: "https://service.stub.invalid/\(UUID().uuidString)/")!
    }

    /// The service sends this visit to the ssoam2 sign-in form.
    private static func enqueueSignInForm(for service: URL) {
        SSOServerStub.enqueue(.follow(to: loginURL), for: service)
        SSOServerStub.enqueue(.page(Pages.ssoam2Login), for: loginURL)
    }

    private struct Outcome {
        let result: Result<Bool, Error>
        /// `SSOLoginService.storedPasswordRejected` when the sign-in ended.
        let rejected: Bool
    }

    /// Runs `body` with the latch set to `rejected`, then puts the latch and the login stamp back.
    /// Both are real `Defaults` keys, which `BackendSessionTests` reads too.
    private func withLatch<T>(_ rejected: Bool, _ body: () async -> T) async -> T {
        await withExclusiveRealDefaults {
            let saved = (SSOLoginService.storedPasswordRejected, Defaults[.ssoLoginTimestamp])
            SSOLoginService.storedPasswordRejected = rejected
            defer { (SSOLoginService.storedPasswordRejected, Defaults[.ssoLoginTimestamp]) = saved }
            return await body()
        }
    }

    private func signIn(
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

    private var posts: [SSOServerStub.Request] {
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

    // MARK: - Moodle token renewal

    private actor HarvestLog {
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
}
