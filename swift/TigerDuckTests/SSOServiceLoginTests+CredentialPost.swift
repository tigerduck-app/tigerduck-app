// Where the sign-in form's password POST may go, in an SSO sign-in and a Moodle token renewal. An
// extension of `SSOServiceLoginTests`, so these run in its serialized order: they share the stub's
// queues, the SSO probe's URL and the stored-password latch.
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

    /// Where ssoam2 sends a browser once the password is accepted.
    nonisolated static let authorizeCallback = URL(
        string: "https://ssoam2.ntust.edu.tw/connect/authorize/callback?client_id=stub"
    )!

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

    // MARK: - Moodle token renewal

    private func renewal(from page: String) async -> (Result<String, Error>, Bool) {
        let renewal = pageWalk(log: HarvestLog(), from: page, at: Self.loginURL)
        return await withLatch(false) { () async -> (Result<String, Error>, Bool) in
            (await Self.result { try await renewal.refreshTokenIfNeeded() }, SSOLoginService.storedPasswordRejected)
        }
    }

    @Test(
        "a renewal whose password POST meets a redirect it may not follow ends there",
        arguments: refusedRedirects
    )
    func renewalStopsAtARefusedRedirect(status: Int, location: String) async throws {
        let target = try #require(URL(string: location))
        SSOServerStub.reset()
        SSOServerStub.enqueue(.redirect(status, to: target), for: Self.postURL)
        let (outcome, rejected) = await renewal(from: Pages.ssoam2Login)
        #expect(requests(to: target).isEmpty)
        #expect(posts.map(\.url) == [Self.postURL])
        guard case .failure(MoodleWebserviceError.httpStatus(code: status)) = outcome else {
            Issue.record("expected httpStatus(\(status)), got \(outcome)")
            return
        }
        #expect(!rejected)
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
        let (outcome, _) = await renewal(from: Pages.ssoam2Login)
        guard case .success("followed-token") = outcome else {
            Issue.record("expected the token, got \(outcome)")
            return
        }
        #expect(posts.map(\.url) == [Self.postURL])
        #expect(requests(to: Self.authorizeCallback).map(\.method) == ["GET"])
        #expect(requests(to: Self.authorizeCallback).map(\.body) == [""])
    }
}
