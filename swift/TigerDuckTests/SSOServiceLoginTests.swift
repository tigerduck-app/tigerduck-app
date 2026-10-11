import Defaults
import Foundation
import Testing
@testable import TigerDuck

/// `SSOLoginService.ensureServiceLogin` against `SSOServerStub`. Serialized: the SSO probe asks
/// one fixed URL, and the stub's queues are shared.
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

    /// The sign-in, with the stub reset first and the probe's login stamp put back after.
    private func signIn(_ serviceURL: URL, setUp: () -> Void) async -> Result<Bool, Error> {
        SSOServerStub.reset()
        setUp()
        let stamp = Defaults[.ssoLoginTimestamp]
        defer { Defaults[.ssoLoginTimestamp] = stamp }
        do {
            return .success(try await SSOLoginService.ensureServiceLogin(
                session: SSOServerStub.session(),
                serviceURL: serviceURL,
                studentId: "B00000000",
                password: "unused",
                generation: NTUSTSessionManager.shared.generation
            ))
        } catch {
            return .failure(error)
        }
    }

    private var posts: [SSOServerStub.Request] {
        SSOServerStub.requests.filter { $0.method == "POST" }
    }

    @Test("a maintenance page without a live SSO session is not a sign-in")
    func maintenancePageIsNoSignIn() async {
        let service = Self.serviceURL()
        let result = await signIn(service) {
            SSOServerStub.enqueue(.page(Pages.maintenance, status: 503), for: service)
            SSOServerStub.enqueue(.page(Pages.maintenance, status: 503), for: service)
            SSOServerStub.enqueue(Self.notSignedIn, for: Self.probeURL)
            SSOServerStub.enqueue(Self.notSignedIn, for: Self.probeURL)
        }
        guard case .failure(SSOLoginError.loginFormNotFound) = result else {
            Issue.record("expected loginFormNotFound, got \(result)")
            return
        }
        #expect(posts.isEmpty)
        #expect(SSOServerStub.requests.filter { $0.url == service }.count == 2)
    }

    @Test("ssoam's NetIQ form asks for a browser sign-in")
    func netIQFormNeedsABrowser() async {
        let service = Self.serviceURL()
        let result = await signIn(service) {
            SSOServerStub.enqueue(.follow(to: Pages.netIQLoginURL), for: service)
            SSOServerStub.enqueue(.page(Pages.netIQLogin), for: Pages.netIQLoginURL)
        }
        guard case .failure(SSOLoginError.interactiveLoginRequired) = result else {
            Issue.record("expected interactiveLoginRequired, got \(result)")
            return
        }
        #expect(SSOServerStub.requests.map(\.url) == [service, Pages.netIQLoginURL])
    }

    @Test("a service page with a live SSO session signs in without posting")
    func liveSessionSignsIn() async {
        let service = Self.serviceURL()
        let result = await signIn(service) {
            SSOServerStub.enqueue(.page(Self.servicePage), for: service)
            SSOServerStub.enqueue(.redirect(to: "/Home/Index"), for: Self.probeURL)
        }
        guard case .success(true) = result else {
            Issue.record("expected a sign-in, got \(result)")
            return
        }
        #expect(posts.isEmpty)
    }

    @Test("a visit sent to the campus portal reaches the sign-in form once the service's cookies are gone")
    func portalVisitSignsInThroughTheForm() async {
        let service = Self.serviceURL()
        let portal = "<html><body><h1>臺科大校園入口</h1><a href=\"/login\">登入</a></body></html>"
        let result = await signIn(service) {
            SSOServerStub.enqueue(.page(portal), for: service)
            SSOServerStub.enqueue(Self.notSignedIn, for: Self.probeURL)
            Self.enqueueSignInForm(for: service)
            Self.enqueueSignInForm(for: service)
            SSOServerStub.enqueue(.page(Self.servicePage), for: Self.postURL)
        }
        guard case .success(true) = result else {
            Issue.record("expected a sign-in, got \(result)")
            return
        }
        #expect(posts.map(\.url) == [Self.postURL])
        #expect(posts.first?.body.contains("Username=B00000000") == true)
    }
}
