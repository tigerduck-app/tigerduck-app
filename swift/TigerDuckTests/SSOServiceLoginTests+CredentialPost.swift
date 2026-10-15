// Where a POST carrying a password or a token may go: sign-in forms, forms passing a sign-in on,
// and the library's and backend's sign-ins. An extension of `SSOServiceLoginTests`, so these run
// in its serialized order: they share the stub's queues, the SSO probe's URL and the latch.
import Foundation
import Testing
@testable import TigerDuck

extension SSOServiceLoginTests {
    /// The redirects of the POST that end it: a 307 or a 308 would send the form, password and all,
    /// to its `Location`, and a GET is followed only over HTTPS.
    nonisolated static let refusedRedirects: [(Int, String)] = [
        (307, "https://elsewhere.stub.invalid/account/login"),
        (308, "https://elsewhere.stub.invalid/account/login"),
        (302, "http://ssoam2.ntust.edu.tw/connect/authorize/callback?client_id=stub"),
    ]

    /// Form actions the password may not go to.
    nonisolated static let refusedActions = [
        "https://elsewhere.stub.invalid/account/login",
        "http://ssoam2.ntust.edu.tw/account/login",
    ]

    /// Where ssoam2 sends a browser once the password is accepted.
    nonisolated static let authorizeCallback = URL(
        string: "https://ssoam2.ntust.edu.tw/connect/authorize/callback?client_id=stub"
    )!

    /// The fixture sign-in form, posting to `action`.
    static func signInForm(postingTo action: String) throws -> String {
        let fixture = #"action="/account/login?ReturnUrl=%2Fconnect%2Fauthorize%2Fcallback""#
        try #require(Pages.ssoam2Login.contains(fixture))
        return Pages.ssoam2Login.replacingOccurrences(of: fixture, with: "action=\"\(action)\"")
    }

    private func requests(to url: URL) -> [SSOServerStub.Request] {
        SSOServerStub.requests.filter { $0.url == url }
    }

    // MARK: - SSO sign-in

    @Test(
        "a sign-in whose password POST meets a redirect it may not follow ends there",
        arguments: refusedRedirects
    )
    func signInStopsAtARefusedRedirect(status: Int, location: String) async throws {
        let service = Self.serviceURL()
        let target = try #require(URL(string: location))
        let outcome = await signIn(service) {
            Self.enqueueSignInForm(for: service)
            Self.enqueueSignInForm(for: service)
            // Read as the answer, the sign-in form in the redirect would pass for a refusal.
            SSOServerStub.enqueue(.redirect(status, to: target, body: Pages.ssoam2Login), for: Self.postURL)
        }
        #expect(requests(to: target).isEmpty)
        #expect(posts.map(\.url) == [Self.postURL])
        guard case .failure(SSOLoginError.invalidResponse) = outcome.result else {
            Issue.record("expected invalidResponse, got \(outcome.result)")
            return
        }
        #expect(!outcome.rejected)
    }

    @Test("a sign-in whose password POST is redirected as a GET over HTTPS signs in", arguments: [301, 302, 303])
    func signInFollowsARedirectAsAGet(status: Int) async {
        let service = Self.serviceURL()
        let outcome = await signIn(service) {
            Self.enqueueSignInForm(for: service)
            Self.enqueueSignInForm(for: service)
            SSOServerStub.enqueue(.redirect(status, to: Self.authorizeCallback), for: Self.postURL)
            SSOServerStub.enqueue(.page(Self.servicePage), for: Self.authorizeCallback)
            SSOServerStub.enqueue(.redirect(to: "/Home/Index"), for: Self.probeURL)
        }
        guard case .success(true) = outcome.result else {
            Issue.record("expected a sign-in, got \(outcome.result)")
            return
        }
        #expect(posts.map(\.url) == [Self.postURL])
        #expect(requests(to: Self.authorizeCallback).map(\.method) == ["GET"])
        #expect(requests(to: Self.authorizeCallback).map(\.body) == [""])
    }

    @Test("a sign-in posts no password to a form action off ssoam2 or over plain HTTP", arguments: refusedActions)
    func signInPostsNoPasswordOffTheSignInHost(action: String) async throws {
        let service = Self.serviceURL()
        let page = try Self.signInForm(postingTo: action)
        let outcome = await signIn(service) {
            for _ in 0..<2 {
                SSOServerStub.enqueue(.follow(to: Self.loginURL), for: service)
                SSOServerStub.enqueue(.page(page), for: Self.loginURL)
            }
        }
        #expect(posts.isEmpty)
        // No password went out, so the sign-in does not ask the user to check it.
        guard case .failure(SSOLoginError.invalidResponse) = outcome.result else {
            Issue.record("expected invalidResponse, got \(outcome.result)")
            return
        }
        #expect(!outcome.rejected)
    }

    // MARK: - Moodle token renewal

    /// A renewal from `page`, and after a failure one more, which the pause should keep from
    /// harvesting. `harvests` counts both.
    private func renewal(from page: String) async -> (Result<String, Error>, rejected: Bool, harvests: Int) {
        let log = HarvestLog()
        let renewal = pageWalk(log: log, from: page, at: Self.loginURL)
        let (outcome, rejected) = await withLatch(false) { () async -> (Result<String, Error>, Bool) in
            let outcome = await Self.result { try await renewal.refreshTokenIfNeeded() }
            if case .failure = outcome { _ = try? await renewal.refreshTokenIfNeeded() }
            return (outcome, SSOLoginService.storedPasswordRejected)
        }
        return (outcome, rejected, await log.calls)
    }

    @Test(
        "a renewal whose password POST meets a redirect it may not follow ends there",
        arguments: refusedRedirects
    )
    func renewalStopsAtARefusedRedirect(status: Int, location: String) async throws {
        let target = try #require(URL(string: location))
        SSOServerStub.reset()
        SSOServerStub.enqueue(.redirect(status, to: target), for: Self.postURL)
        let (outcome, rejected, harvests) = await renewal(from: Pages.ssoam2Login)
        #expect(requests(to: target).isEmpty)
        #expect(posts.map(\.url) == [Self.postURL])
        guard case .failure(MoodleWebserviceError.httpStatus(code: status)) = outcome else {
            Issue.record("expected httpStatus(\(status)), got \(outcome)")
            return
        }
        #expect(!rejected)
        // Paused as other failures are: the second renewal sent nothing.
        #expect(harvests == 1)
    }

    @Test("a renewal whose password POST is redirected as a GET over HTTPS gets the token", arguments: [301, 302, 303])
    func renewalFollowsARedirectAsAGet(status: Int) async {
        let triple = Data("signature:::followed-token:::private-token".utf8).base64EncodedString()
        SSOServerStub.reset()
        SSOServerStub.enqueue(.redirect(status, to: Self.authorizeCallback), for: Self.postURL)
        SSOServerStub.enqueue(
            .page(#"<script>window.location = "moodlemobile://token=\#(triple)";</script>"#),
            for: Self.authorizeCallback
        )
        let (outcome, _, _) = await renewal(from: Pages.ssoam2Login)
        guard case .success("followed-token") = outcome else {
            Issue.record("expected the token, got \(outcome)")
            return
        }
        #expect(posts.map(\.url) == [Self.postURL])
        #expect(requests(to: Self.authorizeCallback).map(\.method) == ["GET"])
        #expect(requests(to: Self.authorizeCallback).map(\.body) == [""])
    }

    @Test("a renewal posts no password to a form action off ssoam2 or over plain HTTP", arguments: refusedActions)
    func renewalPostsNoPasswordOffTheSignInHost(action: String) async throws {
        let page = try Self.signInForm(postingTo: action)
        SSOServerStub.reset()
        let (outcome, rejected, harvests) = await renewal(from: page)
        #expect(SSOServerStub.requests.isEmpty)
        guard case .failure(MoodleWebserviceError.malformedResponse) = outcome else {
            Issue.record("expected malformedResponse, got \(outcome)")
            return
        }
        #expect(!rejected)
        #expect(harvests == 1)
    }

    // MARK: - Forms that pass the sign-in on

    /// An OIDC or SAML form that passes the sign-in on to `action`, with its token.
    static func bridgeForm(postingTo action: String) -> String {
        """
        <html><body><form method="post" action="\(action)">
        <input type="hidden" name="id_token" value="stub-token"><input type="hidden" name="state" value="stub">
        </form></body></html>
        """
    }

    nonisolated static let refusedBridgeActions = [
        "https://elsewhere.stub.invalid/signin-oidc",
        "http://courseselection.ntust.edu.tw/signin-oidc",
    ]

    @Test("a sign-in posts no token to a form off the school's hosts or over plain HTTP", arguments: refusedBridgeActions)
    func signInPostsNoTokenOffTheSchool(action: String) async throws {
        let service = Self.serviceURL()
        let target = try #require(URL(string: action))
        let outcome = await signIn(service) {
            Self.enqueueSignInForm(for: service)
            Self.enqueueSignInForm(for: service)
            SSOServerStub.enqueue(.redirect(302, to: Self.authorizeCallback), for: Self.postURL)
            SSOServerStub.enqueue(.page(Self.bridgeForm(postingTo: action)), for: Self.authorizeCallback)
        }
        #expect(requests(to: target).isEmpty)
        guard case .failure(SSOLoginError.invalidResponse) = outcome.result else {
            Issue.record("expected invalidResponse, got \(outcome.result)")
            return
        }
        #expect(!outcome.rejected)
    }

    @Test("a sign-in whose form passing it on meets a 307 or a 308 ends there", arguments: [307, 308])
    func signInStopsAtABridgeRedirect(status: Int) async throws {
        let service = Self.serviceURL()
        let target = try #require(URL(string: "https://courseselection.ntust.edu.tw/signin-oidc"))
        let elsewhere = try #require(URL(string: "https://elsewhere.stub.invalid/signin-oidc"))
        let outcome = await signIn(service) {
            Self.enqueueSignInForm(for: service)
            Self.enqueueSignInForm(for: service)
            SSOServerStub.enqueue(.redirect(302, to: Self.authorizeCallback), for: Self.postURL)
            SSOServerStub.enqueue(.page(Self.bridgeForm(postingTo: target.absoluteString)), for: Self.authorizeCallback)
            SSOServerStub.enqueue(.redirect(status, to: elsewhere), for: target)
        }
        #expect(requests(to: target).map(\.method) == ["POST"])
        #expect(requests(to: elsewhere).isEmpty)
        guard case .failure(SSOLoginError.invalidResponse) = outcome.result else {
            Issue.record("expected invalidResponse, got \(outcome.result)")
            return
        }
    }

    @Test("a renewal posts no Moodle code over plain HTTP, and pauses without a refusal")
    func renewalPostsNoCodeOverPlainHTTP() async throws {
        let target = try #require(URL(string: "http://moodle2.ntust.edu.tw/auth/oidc/"))
        SSOServerStub.reset()
        SSOServerStub.enqueue(.page("""
            <html><body><form method="post" action="\(target.absoluteString)">
            <input type="hidden" name="code" value="stub-code"><input type="hidden" name="state" value="stub">
            <input type="hidden" name="iss" value="https://ssoam2.ntust.edu.tw">
            </form></body></html>
            """), for: Self.postURL)
        let (outcome, rejected, harvests) = await renewal(from: Pages.ssoam2Login)
        #expect(requests(to: target).isEmpty)
        guard case .failure(MoodleWebserviceError.malformedResponse) = outcome else {
            Issue.record("expected malformedResponse, got \(outcome)")
            return
        }
        #expect(!rejected)
        #expect(harvests == 1)
    }

    @Test("a renewal whose Moodle code POST meets a 307 or a 308 ends there", arguments: [307, 308])
    func renewalStopsAtABridgeRedirect(status: Int) async throws {
        let target = try #require(URL(string: "https://moodle2.ntust.edu.tw/auth/oidc/"))
        let elsewhere = try #require(URL(string: "https://elsewhere.stub.invalid/auth/oidc/"))
        SSOServerStub.reset()
        SSOServerStub.enqueue(.page("""
            <html><body><form method="post" action="\(target.absoluteString)">
            <input type="hidden" name="code" value="stub-code"><input type="hidden" name="state" value="stub">
            <input type="hidden" name="iss" value="https://ssoam2.ntust.edu.tw">
            </form></body></html>
            """), for: Self.postURL)
        SSOServerStub.enqueue(.redirect(status, to: elsewhere), for: target)
        let (outcome, rejected, _) = await renewal(from: Pages.ssoam2Login)
        #expect(requests(to: target).map(\.method) == ["POST"])
        #expect(requests(to: elsewhere).isEmpty)
        guard case .failure(MoodleWebserviceError.httpStatus(code: status)) = outcome else {
            Issue.record("expected httpStatus(\(status)), got \(outcome)")
            return
        }
        #expect(!rejected)
    }

    // MARK: - The library's and the backend's sign-in

    @Test("the library sign-in stops at a 307 or a 308 rather than send the password on", arguments: [307, 308])
    func librarySignInStopsAtARedirect(status: Int) async throws {
        let login = try #require(URL(string: "https://api.lib.ntust.edu.tw/v1/passport/login"))
        let elsewhere = try #require(URL(string: "https://elsewhere.stub.invalid/passport/login"))
        SSOServerStub.reset()
        SSOServerStub.enqueue(.redirect(status, to: elsewhere), for: login)
        await #expect(throws: (any Error).self) {
            try await LibraryService.requestToken(username: "B00000000", password: "unused", session: SSOServerStub.session())
        }
        #expect(requests(to: login).map(\.method) == ["POST"])
        #expect(requests(to: elsewhere).isEmpty)
    }

    @Test("the backend sign-in stops at a 307 or a 308 rather than send the Moodle token on", arguments: [307, 308])
    func backendSignInStopsAtARedirect(status: Int) async throws {
        let base = try #require(URL(string: "https://backend.stub.invalid/v3"))
        let elsewhere = try #require(URL(string: "https://elsewhere.stub.invalid/v3/auth/login"))
        SSOServerStub.reset()
        SSOServerStub.enqueue(.redirect(status, to: elsewhere), for: base.appendingPathComponent("auth/login"))
        let manager = AuthTokenManager(
            baseURLProvider: { base }, deviceUUID: "test-device", session: SSOServerStub.session(),
            tokens: .init(load: { _ in nil }, save: { _, _ in }, delete: { _ in }), beginBackgroundTask: { {} }
        )
        await #expect(throws: AuthTokenManager.AuthError.loginFailed) {
            _ = try await manager.login(
                studentId: "B00000000", moodleToken: "moodle-token", moodlePrivateToken: nil, platform: "ios"
            )
        }
        #expect(requests(to: elsewhere).isEmpty)
    }
}
