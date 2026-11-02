#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct BrowserSessionSignInTests {
    private static let site = URL(string: "https://stuinfosys.ntust.edu.tw/StudentInformation")!
    private static let moodle = URL(string: "https://moodle2.ntust.edu.tw/my/")!

    private static func cookie(_ name: String, _ domain: String, _ value: String = "v") -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: value, .domain: domain, .path: "/", .secure: "TRUE"])!
    }

    private static let identity = ".AspNetCore.Identity.Application"
    private static let appJars = [
        [cookie(identity, "ssoam2.ntust.edu.tw", "harvest"), cookie("MoodleSession", "moodle2.ntust.edu.tw", "app")],
        [cookie(identity, "ssoam2.ntust.edu.tw", "school"), cookie("shared", ".ntust.edu.tw"),
         cookie("ASP.NET_SessionId", "courseselection.ntust.edu.tw", "app")],
    ]
    /// What the browser holds once its page passed SSO: SSO's renewed session, the site's own, and
    /// those of other sites the student opened.
    private static let browserJar = [
        cookie(identity, "ssoam2.ntust.edu.tw", "renewed"),
        cookie("ASP.NET_SessionId", "stuinfosys.ntust.edu.tw", "site"),
        cookie("ASP.NET_SessionId", "courseselection.ntust.edu.tw", "other"),
        cookie("MoodleSession", "moodle2.ntust.edu.tw", "browser"),
        cookie("tracker", ".ntust.edu.tw", "site"),
    ]

    private final class Browser {
        var put: [HTTPCookie] = []
        var pages: [(entry: URL, target: URL)] = []
        var kept: [HTTPCookie] = []
        var resets = 0
        var passes = true
        var duringPage: () -> Void = {}
        var onPut: () -> Void = {}
        /// The app's SSO session: a lapsed one is renewed once, when `renews`.
        var sessionIsLive = true
        var renews = true
        var renewals = 0
        var checks = 0
        var duringRenewal: () -> Void = {}
        var loaded: [URL] = []

        func signIn(_ signIn: SignIn = TestSignIn().signIn, to target: URL) async -> Bool {
            let sessionSignIn = BrowserSessionSignIn(
                putCookie: { self.put.append($0); self.onPut() },
                browserCookies: { BrowserSessionSignInTests.browserJar },
                runPage: { entry, target in
                    self.pages.append((entry, target))
                    self.duringPage()
                    return self.passes
                },
                renewSession: { _ in
                    self.checks += 1
                    if !self.sessionIsLive, self.renews {
                        self.renewals += 1
                        self.sessionIsLive = true
                    }
                    self.duringRenewal()
                    return self.sessionIsLive
                },
                appJars: { self.sessionIsLive ? BrowserSessionSignInTests.appJars : [] },
                keepCookie: { self.kept.append($0) },
                storeResets: { self.resets }
            )
            return await sessionSignIn.signIn(for: signIn, to: target)
        }
    }

    @Test func aSchoolSiteGetsSSOsSessionAndGivesBackSSOsAlone() async {
        let browser = Browser()

        #expect(await browser.signIn(to: Self.site))

        #expect(browser.put.map(\.value) == ["harvest", "school"])
        #expect(browser.put.allSatisfy { $0.domain == "ssoam2.ntust.edu.tw" })
        #expect(browser.pages.map(\.entry) == [Self.site])
        #expect(browser.kept.map(\.value) == ["renewed"])
    }

    @Test func moodlesSignInSharesTheSignInHostsCookiesAsBefore() async {
        let browser = Browser()

        #expect(await browser.signIn(to: Self.moodle))

        #expect(browser.checks == 0, "Moodle's sign-in goes on as before, without the check")
        #expect(browser.put.map(\.value) == ["harvest", "app", "school", "v"])
        #expect(browser.pages.map(\.entry) == [BrowserRouting.webSignInURL])
        #expect(browser.kept.map(\.value) == ["renewed", "browser", "site"])
    }

    @Test func aLapsedSSOSessionIsRenewedOnceAndThenItsCookiesGoIn() async {
        let browser = Browser()
        browser.sessionIsLive = false

        #expect(await browser.signIn(to: Self.site))
        #expect(await browser.signIn(to: Self.site))

        #expect(browser.checks == 2)
        #expect(browser.renewals == 1)
        #expect(browser.put.map(\.value) == ["harvest", "school", "harvest", "school"])
        #expect(browser.pages.count == 2)
    }

    @Test func aRenewalThatFailsPutsNothingInAndRunsNoPage() async {
        let browser = Browser()
        browser.sessionIsLive = false
        browser.renews = false

        #expect(!(await browser.signIn(to: Self.site)))

        #expect(browser.put.isEmpty && browser.pages.isEmpty && browser.kept.isEmpty)
    }

    @Test func aSignOutDuringTheRenewalKeepsTheCookiesOut() async {
        let browser = Browser()
        let account = TestSignIn()
        browser.sessionIsLive = false
        browser.duringRenewal = { account.signOut() }

        #expect(!(await browser.signIn(account.signIn, to: Self.site)))

        #expect(browser.renewals == 1)
        #expect(browser.put.isEmpty && browser.pages.isEmpty && browser.kept.isEmpty)
    }

    @Test func aRenewalThatFailsLeavesSSOsFormToTheStudentWithoutALoop() async {
        let browser = Browser()
        browser.sessionIsLive = false
        browser.renews = false
        let signIn = BrowserSignIn(hasSession: { false }, signedInURL: { _ in nil })
        signIn.signInWithSession = { [weak signIn] in await browser.signIn(to: signIn?.target ?? Self.moodle) }
        signIn.load = { browser.loaded.append($0) }

        #expect(signIn.reachedSignInPage(returningTo: Self.site))
        await signIn.settle()
        // The page loads again and SSO's form shows; reached again, it stays.
        #expect(browser.loaded == [Self.site])
        #expect(!signIn.reachedSignInPage(returningTo: Self.site))
        await signIn.settle()

        #expect(browser.checks == 1)
        #expect(browser.put.isEmpty && browser.pages.isEmpty)
        #expect(browser.loaded == [Self.site])
    }

    @Test func aSignOutDuringThePageKeepsTheCookiesOut() async {
        let browser = Browser()
        let account = TestSignIn()
        browser.duringPage = { account.signOut() }

        #expect(!(await browser.signIn(account.signIn, to: Self.site)))

        #expect(browser.pages.count == 1)
        #expect(browser.kept.isEmpty)
    }

    @Test func aSignOutWhileTheCookiesGoInStopsBeforeTheNextAndThePage() async {
        let browser = Browser()
        let account = TestSignIn()
        browser.onPut = { account.signOut() }

        #expect(!(await browser.signIn(account.signIn, to: Self.site)))

        #expect(browser.put.count == 1)
        #expect(browser.pages.isEmpty)
        #expect(browser.kept.isEmpty)
    }

    @Test func aStorageResetDuringThePageKeepsTheCookiesOut() async {
        let browser = Browser()
        browser.duringPage = { browser.resets += 1 }

        #expect(!(await browser.signIn(to: Self.moodle)))

        #expect(browser.kept.isEmpty)
    }

    @Test func aPageThatStoppedAtAPasswordKeepsNothing() async {
        let browser = Browser()
        browser.passes = false

        #expect(!(await browser.signIn(to: Self.site)))

        #expect(browser.pages.count == 1)
        #expect(browser.kept.isEmpty)
    }

    @Test func theDemoAccountSignsNothingIn() async {
        let browser = Browser()
        let demo = SignInSeries()
        demo.startDemo()

        #expect(!(await browser.signIn(demo.currentSignIn, to: Self.site)))

        #expect(browser.put.isEmpty && browser.pages.isEmpty && browser.kept.isEmpty)
    }
}
#endif
