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

    /// Refused sign-in steps and SSO returns, and the address opening each at risk loads.
    static let signInSteps: [(refused: String, opens: String)] = [
        // BrowserSignIn's autologin link: its one-time key stays behind and its urltogo opens.
        (
            "https://moodle2.ntust.edu.tw/admin/tool/mobile/autologin.php?userid=42&key=one-time"
                + "&urltogo=https%3A%2F%2Fmoodle2.ntust.edu.tw%2Fcourse%2Fview.php%3Fid%3D7",
            "https://moodle2.ntust.edu.tw/course/view.php?id=7"
        ),
        ("https://moodle2.ntust.edu.tw/auth/oidc/?code=one-time&state=s", "https://moodle2.ntust.edu.tw"),
        ("https://moodle2.ntust.edu.tw/login/index.php", "https://moodle2.ntust.edu.tw"),
        (
            "https://ssoam2.ntust.edu.tw/account/login?ReturnUrl=%2Fconnect%2Fauthorize%2Fcallback%3Fclient_id%3Dmoodle"
                + "%26redirect_uri%3Dhttps%253A%252F%252Fmoodle2.ntust.edu.tw%252Fauth%252Foidc%252F%26state%3Ds%26nonce%3Dn",
            "https://moodle2.ntust.edu.tw"
        ),
        (
            "https://ssoam2.ntust.edu.tw/connect/authorize?client_id=x"
                + "&redirect_uri=https%3A%2F%2Fsa02.ntust.edu.tw%2FWebCounseling%2FOAuth2%2FCallback&state=s",
            "https://sa02.ntust.edu.tw/WebCounseling/OAuth2/Callback"
        ),
        (
            "https://sa02.ntust.edu.tw/WebCounseling/OAuth2/Callback?code=one-time&state=s#id_token=t",
            "https://sa02.ntust.edu.tw/WebCounseling/OAuth2/Callback"
        ),
        ("https://stuinfosys.ntust.edu.tw/Auth/Return?ticket=one-time&lang=zh", "https://stuinfosys.ntust.edu.tw/Auth/Return?lang=zh"),
        ("https://suggestionbox.ntust.edu.tw/form?id=3", "https://suggestionbox.ntust.edu.tw/form?id=3"),
    ]

    @Test("a page opened at risk loads no sign-in's credential: a sign-in step opens the page it leads to", arguments: signInSteps)
    func noCredentialOpensAtRisk(step: (refused: String, opens: String)) throws {
        let refused = try #require(URL(string: step.refused))
        let page = Self.refusedPage(refused)
        #expect(page.sheetAddress?.absoluteString == step.opens)
        page.openAtRisk()
        #expect(page.openedAtRisk?.absoluteString == step.opens)
        #expect(page.certificates.acceptance.allows("0f0e", from: try #require(BrowserRouting.host(of: refused))))
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

    @Test("a page opened at risk loads its own address, not a site's sign-in link, and keeps every cookie of its host")
    func theOpeningIsLeftAsItIs() async throws {
        let start = URL(string: "https://querycourse.ntust.edu.tw/QueryCourse/")!
        let page = Self.refusedPage(start)
        page.openAtRisk()
        // Past `BrowserSchoolSites.cookieBudget`, so a page on the browser's own store would drop them.
        let cookies = try (0..<3).map { index in
            try #require(HTTPCookie(properties: [
                .name: "large\(index)", .value: String(repeating: "a", count: 3000),
                .domain: "querycourse.ntust.edu.tw", .path: "/",
            ]))
        }
        for cookie in cookies { await page.store.httpCookieStore.setCookie(cookie) }

        _ = BrowserNavigator(page: page, auth: nil).makeView(opening: start)
        var loaded: [URL] = []
        page.signIn.load = { loaded.append($0) }
        try await waitUntil { !loaded.isEmpty }
        #expect(loaded == [start])
        #expect(Set(await page.store.httpCookieStore.allCookies().map(\.name)) == ["large0", "large1", "large2"])
    }

    @Test("opening a page at risk brings back no prompt the student closed unanswered; a new browser does")
    func theAtRiskWebViewOffersNoClosedPromptAgain() throws {
        let prompts = TLSPinMismatchQueue(engine: TLSPinFixtures.engine(document: TLSPinFixtures.promptRootsDocument)) {}
        prompts.isForeground = true
        let mismatch = TLSPinMismatchQueueTests.mismatch()
        prompts.report(mismatch)
        prompts.dismiss(mismatch)

        let page = Self.refusedPage(URL(string: "https://at-risk.invalid/form")!)
        page.openAtRisk()
        _ = BrowserNavigator(page: page, auth: nil).makeView(opening: try #require(page.openedAtRisk), prompts: prompts)
        page.signIn.load = { _ in }
        prompts.report(mismatch)
        #expect(prompts.prompt == nil)

        let browser = BrowserPage()
        _ = BrowserNavigator(page: browser, auth: nil).makeView(opening: URL(string: "https://at-risk.invalid/")!, prompts: prompts)
        browser.signIn.load = { _ in }
        prompts.report(mismatch)
        #expect(prompts.prompt == mismatch)
    }

    @Test("zoom and desktop site on a page opened at risk are not saved for its host, as they are on the browser's own store")
    func siteSettingsAtRiskAreNotSaved() {
        let host = "at-risk.ntust.edu.tw"
        let start = URL(string: "https://\(host)/page")!
        defer {
            BrowserSites.change(for: AccountSession.school.currentSignIn) {
                $0.setZoom(BrowserZoom.standard, for: host)
                $0.setDesktop(false, for: host)
            }
        }
        let page = Self.refusedPage(start)
        page.openAtRisk()
        _ = BrowserNavigator(page: page, auth: nil).makeView(opening: start)
        page.signIn.load = { _ in }
        #expect(page.host == host)
        page.zoomIn()
        page.setDesktopSite(true)
        #expect(BrowserSites.stored.zoom(for: host) == BrowserZoom.standard)
        #expect(!BrowserSites.stored.isDesktop(host))

        let own = BrowserPage()
        _ = BrowserNavigator(page: own, auth: nil).makeView(opening: start)
        own.signIn.load = { _ in }
        own.zoomIn()
        #expect(BrowserSites.stored.zoom(for: host) != BrowserZoom.standard)
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
