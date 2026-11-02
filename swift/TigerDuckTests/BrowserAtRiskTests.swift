#if os(iOS)
import Foundation
import Testing
import WebKit
@testable import TigerDuck

@MainActor
struct BrowserAtRiskTests {
    private static let host = "suggestionbox.ntust.edu.tw"
    private static let refused = URL(string: "https://\(host)/form")!
    private static let moodle = URL(string: "https://moodle2.ntust.edu.tw/my/")!
    private static let sso = URL(string: "https://ssoam2.ntust.edu.tw/nidp/app/login")!

    /// A page whose last load `refused` for its certificate, with `leaf` served at the refusal.
    static func refusedPage(_ refused: URL = refused, leaf: String = "0f0e") -> BrowserPage {
        let page = BrowserPage()
        page.shown.start = URL(string: "https://i.ntust.edu.tw/student")
        page.failure = .certificate(
            host: refused.host(percentEncoded: false) ?? "", refusal: .init(url: refused, leaf: leaf)
        )
        return page
    }

    @Test("a page opened at risk gets a store of its own that keeps nothing on disk, and each acceptance a new one")
    func eachAcceptanceGetsItsOwnStore() {
        let page = Self.refusedPage()
        page.openAtRisk()
        #expect(!page.store.isPersistent)
        #expect(page.store !== BrowserData.shared.store)
        #expect(page.openedAtRisk == Self.refused)
        #expect(page.certificates.acceptance.allows("0f0e", from: Self.host))
        #expect(!BrowserPage().certificates.acceptance.allows("0f0e", from: Self.host))

        let first = page.store
        let other = URL(string: "https://sa.ntust.edu.tw/")!
        page.failure = .certificate(host: "sa.ntust.edu.tw", refusal: .init(url: other, leaf: "0a0b"))
        page.openAtRisk()
        #expect(page.store !== first)
        #expect(!page.store.isPersistent)
        #expect(page.openedAtRisk == other)
        #expect(page.certificates.acceptance.allows("0f0e", from: Self.host))
        #expect(page.certificates.acceptance.allows("0a0b", from: "sa.ntust.edu.tw"))
    }

    @Test("the web view built for a page opened at risk runs on that page's own store")
    func theWebViewUsesTheIsolatedStore() throws {
        // A host that never resolves, so the load reaches no one.
        let page = Self.refusedPage(URL(string: "https://at-risk.invalid/form")!)
        page.openAtRisk()
        let navigator = BrowserNavigator(page: page, auth: nil)
        let container = navigator.makeView(opening: try #require(page.openedAtRisk))
        let webView = try #require(container.subviews.compactMap { $0 as? WKWebView }.last)
        #expect(webView.configuration.websiteDataStore === page.store)
        #expect(!webView.configuration.websiteDataStore.isPersistent)
        webView.stopLoading()
    }

    @Test("in a browser opened at risk no sign-in ever runs, for any host, SSO's own form included")
    func noSignInRunsAtRisk() async {
        let page = Self.refusedPage()
        page.openAtRisk()
        var loaded: [URL] = []
        var sessionSignIns = 0
        page.signIn.load = { loaded.append($0) }
        page.signIn.signInWithSession = {
            sessionSignIns += 1
            return true
        }

        for target in [Self.moodle, Self.refused, Self.sso] {
            #expect(!page.signIn.reachedSignInPage(returningTo: target))
        }
        page.signIn.retry()
        await page.signIn.open(Self.moodle)
        await page.signIn.settle()
        #expect(loaded.isEmpty)
        #expect(sessionSignIns == 0)
        #expect(page.signIn.phase == .idle)
    }

    @Test("no cookie a page opened at risk sets reaches the browser's store, the app's jar or a sign-in")
    func cookiesStayInTheIsolatedStore() async throws {
        let page = Self.refusedPage()
        page.openAtRisk()
        let value = UUID().uuidString
        let cookie = try #require(HTTPCookie(properties: [
            .name: "AuthServer", .value: value, .domain: ".ntust.edu.tw", .path: "/", .secure: "TRUE",
        ]))
        await page.store.httpCookieStore.setCookie(cookie)
        defer { Task { await page.store.httpCookieStore.deleteCookie(cookie) } }
        #expect(await page.store.httpCookieStore.allCookies().contains { $0.value == value })

        let normal = BrowserPage()
        #expect(!(await normal.store.httpCookieStore.allCookies().contains { $0.value == value }))
        var kept: [HTTPCookie] = []
        let signIn = BrowserSessionSignIn(
            putCookie: { _ in },
            browserCookies: { await normal.store.httpCookieStore.allCookies() },
            runPage: { _, _ in true },
            renewSession: { _ in true },
            appJars: { [] },
            keepCookie: { kept.append($0) },
            storeResets: { 0 }
        )
        _ = await signIn.signIn(for: TestSignIn().signIn, to: Self.refused)
        #expect(!kept.contains { $0.value == value })
        #expect(HTTPCookieStorage.shared.cookies?.contains { $0.value == value } != true)
    }
}
#endif
