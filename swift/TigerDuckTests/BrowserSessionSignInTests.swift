#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct BrowserSessionSignInTests {
    private static let site = URL(string: "https://stuinfosys.ntust.edu.tw/StudentInformation")!
    private static let moodle = URL(string: "https://moodle2.ntust.edu.tw/my/")!

    private static func cookie(_ name: String, _ domain: String, _ value: String = "v", secure: Bool = true, path: String = "/") -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
        if secure { properties[.secure] = "TRUE" }
        return HTTPCookie(properties: properties)!
    }

    /// ssoam2's session, which it sets on `.ntust.edu.tw`; on its own host it keeps only a load
    /// balancer's cookie.
    private static let session = "AuthServer"
    private static let appJars = [
        [cookie(session, ".ntust.edu.tw", "harvest"), cookie("MoodleSession", "moodle2.ntust.edu.tw", "app")],
        [cookie(session, ".ntust.edu.tw", "school"), cookie("BIGipServerpool_ExamSSO_443", "ssoam2.ntust.edu.tw", "balancer"),
         cookie("ntustLan", ".ntust.edu.tw", "insecure", secure: false),
         cookie("ASP.NET_SessionId", "courseselection.ntust.edu.tw", "app")],
    ]
    /// What the browser holds once its page passed SSO: SSO's renewed session, the site's own, and
    /// those of other sites the student opened.
    private static let browserJar = [
        cookie(session, ".ntust.edu.tw", "renewed"),
        cookie(".AspNetCore.Cookies", "stuinfosys.ntust.edu.tw", "site"),
        cookie("ASP.NET_SessionId", "courseselection.ntust.edu.tw", "other"),
        cookie("MoodleSession", "moodle2.ntust.edu.tw", "browser"),
    ]

    private final class Browser {
        var put: [HTTPCookie] = []
        var pages: [(entry: URL, target: URL)] = []
        var kept: [HTTPCookie] = []
        var jar = BrowserSessionSignInTests.browserJar
        var dropped: [HTTPCookie] = []
        var resets = 0
        var passes = true
        var duringPage: () -> Void = {}
        var onPut: () -> Void = {}
        var onDrop: () -> Void = {}
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
                browserCookies: { self.jar },
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
                dropCookie: { self.dropped.append($0); self.onDrop() },
                storeResets: { self.resets }
            )
            return await sessionSignIn.signIn(for: signIn, to: target)
        }
    }

    @Test func aSchoolSiteGetsSSOsSessionAndGivesBackSSOsAlone() async {
        let browser = Browser()

        #expect(await browser.signIn(to: Self.site))

        #expect(browser.put.map(\.value) == ["harvest", "school", "balancer"])
        #expect(browser.put.filter { $0.name == Self.session }.allSatisfy { $0.domain == ".ntust.edu.tw" })
        #expect(browser.pages.map(\.entry) == [Self.site])
        #expect(browser.kept.map(\.value) == ["renewed"])
    }

    @Test func moodlesSignInSharesTheSignInHostsCookiesAsBefore() async {
        let browser = Browser()

        #expect(await browser.signIn(to: Self.moodle))

        #expect(browser.checks == 0, "Moodle's sign-in goes on as before, without the check")
        #expect(browser.put.map(\.value) == ["harvest", "app", "school", "balancer"])
        #expect(browser.pages.map(\.entry) == [BrowserRouting.webSignInURL])
        #expect(browser.kept.map(\.value) == ["renewed", "browser"])
    }

    @Test func aLapsedSSOSessionIsRenewedOnceAndThenItsCookiesGoIn() async {
        let browser = Browser()
        browser.sessionIsLive = false

        #expect(await browser.signIn(to: Self.site))
        #expect(await browser.signIn(to: Self.site))

        #expect(browser.checks == 2)
        #expect(browser.renewals == 1)
        #expect(browser.put.map(\.value) == ["harvest", "school", "balancer", "harvest", "school", "balancer"])
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

    @Test func aSignOutWhileTheLinksSessionGoesStopsBeforeTheNextAndKeepsTheCookiesOut() async {
        let browser = Browser()
        let account = TestSignIn()
        browser.jar += [
            Self.cookie(".AspNet.Cookies", "sa02.ntust.edu.tw", "site"),
            Self.cookie("ASP.NET_SessionId", "sa02.ntust.edu.tw", "site", secure: false),
        ]
        browser.onDrop = { account.signOut() }

        #expect(!(await browser.signIn(account.signIn, to: Self.url("https://sa02.ntust.edu.tw/WebCounseling/OAuth2/Login"))))

        #expect(browser.dropped.count == 1)
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

    /// The browser loads a site's sign-in link again once the hidden page is done with it, and
    /// WebCounseling offers that link only to a browser signed out of it.
    @Test func aSiteEnteredByItsSignInLinkIsLeftSignedOutForTheLinkToLoadAgain() async {
        let link = Self.url("https://sa02.ntust.edu.tw/WebCounseling/OAuth2/Login")
        let browser = Browser()
        browser.jar += [
            Self.cookie(".AspNet.Cookies", "sa02.ntust.edu.tw", "site"),
            Self.cookie("ASP.NET_SessionId", "sa02.ntust.edu.tw", "site", secure: false),
            Self.cookie("ASP.NET_SessionId", "sa02.ntust.edu.tw", "classroom", secure: false, path: "/classroom_user"),
        ]

        #expect(await browser.signIn(to: link))
        #expect(browser.pages.map(\.entry) == [link])
        #expect(browser.dropped.map(\.name) == [".AspNet.Cookies", "ASP.NET_SessionId"])
        #expect(browser.kept.map(\.value) == ["renewed"])

        // A page stopped after the site signed in leaves the same session behind.
        browser.passes = false
        #expect(!(await browser.signIn(to: link)))
        #expect(browser.dropped.count == 4)

        browser.passes = true
        #expect(await browser.signIn(to: Self.url("https://sa02.ntust.edu.tw/WebCounseling/Front_Index/FrontIndex/Index")))
        #expect(browser.dropped.count == 4)
    }

    @Test func aPageThatStoppedAtAPasswordKeepsNothing() async {
        let browser = Browser()
        browser.passes = false

        #expect(!(await browser.signIn(to: Self.site)))

        #expect(browser.pages.count == 1)
        #expect(browser.kept.isEmpty)
    }

    private static func url(_ text: String) -> URL { URL(string: text)! }

    @Test func aLogoutOnTheHiddenPageEndsTheSignInAtOnce() {
        var steps = BrowserSignInSteps(target: Self.site)
        #expect(steps.navigating(to: Self.url("https://stuinfosys.ntust.edu.tw/Account/LogOff"), isMainFrame: false) == .fail)
        #expect(steps.navigating(to: Self.url("https://ssoam2.ntust.edu.tw/connect/endsession"), isMainFrame: true) == .fail)
        var moodle = BrowserSignInSteps(target: Self.moodle)
        #expect(moodle.navigating(to: Self.url("https://moodle2.ntust.edu.tw/login/logout.php?sesskey=k"), isMainFrame: true) == .fail)
        #expect(steps.navigating(to: Self.site, isMainFrame: true) == .allow)
    }

    @Test func aSchoolPageEndsTheSignInOnlyOnceTheRunWentThroughSSO() {
        var steps = BrowserSignInSteps(target: Self.site)
        // The site's own page finishes first and sends the browser on to SSO by a script.
        #expect(steps.navigating(to: Self.site, isMainFrame: true) == .allow)
        #expect(!steps.isSignedIn(at: Self.site))
        #expect(steps.navigating(to: Self.url("https://ssoam2.ntust.edu.tw/connect/authorize?client_id=x"), isMainFrame: true) == .allow)
        #expect(!steps.isSignedIn(at: Self.url("https://ssoam2.ntust.edu.tw/connect/authorize/callback")))
        #expect(steps.isSignedIn(at: Self.url("https://stuinfosys.ntust.edu.tw/Home")))
    }

    /// The school's OIDC flow as its sites run it: the site's own entry, then ssoam2's authorize,
    /// which with SSO's session answers with a form_post page that posts the code to the site.
    @Test func theSchoolsOIDCFlowSignsInWithSSOsSessionAndStopsWhereItCannot() {
        let authorize = Self.url("https://ssoam2.ntust.edu.tw/connect/authorize?client_id=x&response_mode=form_post")
        var steps = BrowserSignInSteps(target: Self.site)
        for address in [
            "https://stuinfosys.ntust.edu.tw/StudentInformation",
            "https://stuinfosys.ntust.edu.tw/StudentInformation/Home/Login?ReturnUrl=%2F",
            authorize.absoluteString,
            "https://stuinfosys.ntust.edu.tw/StudentInformation/signin-oidc",
            "https://stuinfosys.ntust.edu.tw/StudentInformation/Home/OpenIDCallback",
            "https://stuinfosys.ntust.edu.tw/StudentInformation/Home/Index",
        ] {
            #expect(steps.navigating(to: Self.url(address), isMainFrame: true) == .allow, "\(address)")
        }
        #expect(!steps.isSignedIn(at: authorize))
        #expect(steps.isSignedIn(at: Self.url("https://stuinfosys.ntust.edu.tw/StudentInformation/Home/Index")))

        var lapsed = BrowserSignInSteps(target: Self.site)
        #expect(lapsed.navigating(to: authorize, isMainFrame: true) == .allow)
        let form = Self.url("https://ssoam2.ntust.edu.tw/account/login?ReturnUrl=%2Fconnect%2Fauthorize%2Fcallback")
        #expect(lapsed.navigating(to: form, isMainFrame: true) == .fail)

        // A site on ssoam's NetIQ, through the school's own SSO service.
        var netIQ = BrowserSignInSteps(target: Self.url("https://stuinfosys.ntust.edu.tw/SAGraduatesServ/SAGraduates"))
        let service = Self.url("https://stuinfosys.ntust.edu.tw/NTUSTSSOServ/SSO/AMLogin/SAGraduatesServ?ReturnUrl=x")
        #expect(netIQ.navigating(to: service, isMainFrame: true) == .allow)
        #expect(netIQ.navigating(to: Self.url("https://ssoam.ntust.edu.tw/nidp/oauth/nam/authz?client_id=x"), isMainFrame: true) == .fail)

        // A site that signs the student in, then answers with an error page and its own logout.
        var refused = BrowserSignInSteps(target: Self.url("https://stuinfosys.ntust.edu.tw/ThesisAdvisor"))
        #expect(refused.navigating(to: Self.url("https://stuinfosys.ntust.edu.tw/ThesisAdvisor/Account/Logout"), isMainFrame: true) == .fail)
        #expect(refused.navigating(to: Self.url("https://ssoam2.ntust.edu.tw/connect/logout?post_logout_redirect_uri=x"), isMainFrame: true) == .fail)
    }

    @Test func aPasswordFormRecaptchaOrAnotherSiteEndsTheHiddenSignIn() {
        for address in [
            "https://ssoam2.ntust.edu.tw/account/login?ReturnUrl=%2Fconnect%2Fauthorize",
            "https://ssoam.ntust.edu.tw/nidp/app/login",
            "https://moodle2.ntust.edu.tw/login/index.php",
            "https://example.com/",
        ] {
            var steps = BrowserSignInSteps(target: Self.site)
            #expect(steps.navigating(to: Self.url(address), isMainFrame: true) == .fail, "\(address)")
        }
    }

    @Test func moodlesSignInEndsAtAMoodlePageAsBefore() {
        let steps = BrowserSignInSteps(target: Self.moodle)
        #expect(steps.isSignedIn(at: Self.moodle))
        #expect(!steps.isSignedIn(at: Self.site))
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
