#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

struct BrowserRoutingTests {
    private static func url(_ text: String) -> URL { URL(string: text)! }

    @Test(arguments: [
        "https://moodle2.ntust.edu.tw/my/",
        "https://i.ntust.edu.tw/student",
        "https://a.b.ntust.edu.tw/",
        "https://MOODLE2.NTUST.EDU.TW/user/edit.php",
        "https://moodle2.ntust.edu.tw:443/course/view.php?id=1",
    ])
    func schoolPagesLoadInside(_ address: String) {
        #expect(BrowserRouting.decision(for: Self.url(address)) == .load)
    }

    @Test(arguments: [
        "https://docs.google.com/document/d/1",
        "http://moodle2.ntust.edu.tw/my/",
        "https://moodle2.ntust.edu.tw:8443/my/",
        "https://ntust.edu.tw/",
        "https://evilntust.edu.tw/",
        "https://ntust.edu.tw.evil.com/",
        "https://user:pw@moodle2.ntust.edu.tw/",
    ])
    func otherWebPagesAskBeforeLeaving(_ address: String) {
        let url = Self.url(address)
        #expect(BrowserRouting.decision(for: url) == .openOutside(url))
    }

    @Test func aDownloadFollowsARedirectOnlyToASchoolPage() {
        #expect(BrowserRouting.allowsDownloadRedirect(to: Self.url("https://moodle2.ntust.edu.tw/pluginfile.php/1/a.pdf")))
        #expect(!BrowserRouting.allowsDownloadRedirect(to: Self.url("https://files.example.com/a.pdf")))
        #expect(!BrowserRouting.allowsDownloadRedirect(to: Self.url("http://moodle2.ntust.edu.tw/a.pdf")))
        #expect(!BrowserRouting.allowsDownloadRedirect(to: nil))
    }

    @Test func aPageThatCannotBeShownOrIsAnAttachmentIsSaved() {
        func action(_ canShow: Bool, _ disposition: String?, mainFrame: Bool = true) -> BrowserRouting.ResponseAction {
            BrowserRouting.responseAction(canShow: canShow, contentDisposition: disposition, isMainFrame: mainFrame)
        }
        #expect(action(true, nil) == .show)
        #expect(action(true, "inline; filename=\"week1.pdf\"") == .show)
        #expect(action(false, nil) == .download)
        #expect(action(true, "attachment; filename=\"notes.docx\"") == .download)
        #expect(action(true, " Attachment ") == .download)
        #expect(action(false, "attachment", mainFrame: false) == .show)
    }

    @Test func mailLinksGoToTheMailAppAndOtherSchemesNowhere() {
        let mail = Self.url("mailto:someone@mail.ntust.edu.tw")
        #expect(BrowserRouting.decision(for: mail, byLinkTap: true) == .handOff(mail))
        #expect(BrowserRouting.decision(for: mail) == .refuse)
        #expect(BrowserRouting.decision(for: Self.url("about:blank")) == .load)
        for address in ["javascript:alert(1)", "file:///etc/hosts", "about:srcdoc", "data:text/html,hi", "moodlemobile://token=x"] {
            #expect(BrowserRouting.decision(for: Self.url(address)) == .refuse)
        }
    }

    @Test(arguments: [
        "https://moodle2.ntust.edu.tw/login/logout.php?sesskey=abc",
        "https://moodle2.ntust.edu.tw/auth/oidc/logout.php",
        "https://MOODLE2.ntust.edu.tw./LOGIN/Logout.PHP",
        "https://moodle2.ntust.edu.tw//login//logout.php",
        "https://moodle2.ntust.edu.tw/course/../login/logout.php",
        "https://moodle2.ntust.edu.tw/login/%6Cogout.php",
        "https://moodle2.ntust.edu.tw/login/logout.php/extra",
        "http://moodle2.ntust.edu.tw:8080/login/logout.php",
    ])
    func moodleLogoutIsRefusedHoweverItIsWritten(_ address: String) {
        let url = Self.url(address)
        #expect(BrowserRouting.isMoodleLogout(url))
        #expect(BrowserRouting.decision(for: url) == .refuse)
        #expect(!BrowserRouting.isMoodleSignInPage(url))
    }

    @Test func otherPagesThatNameTheLogoutStay() {
        #expect(!BrowserRouting.isMoodleLogout(Self.url("https://moodle2.ntust.edu.tw/my/?next=/login/logout.php")))
        #expect(!BrowserRouting.isMoodleLogout(Self.url("https://i.ntust.edu.tw/login/logout.php")))
    }

    @Test func moodlesLoginPagesMeanSignedOut() {
        #expect(BrowserRouting.isMoodleSignInPage(Self.url("https://moodle2.ntust.edu.tw/login/index.php")))
        #expect(BrowserRouting.isMoodleSignInPage(Self.url("https://moodle2.ntust.edu.tw/login/")))
        #expect(!BrowserRouting.isMoodleSignInPage(Self.url("https://moodle2.ntust.edu.tw/my/")))
        #expect(!BrowserRouting.isMoodleSignInPage(Self.url("https://ssoam2.ntust.edu.tw/login/index.php")))
    }

    @Test func signInLinksAndEntriesAreNoPageToReturnTo() {
        #expect(BrowserRouting.isMoodleReturnPage(Self.url("https://moodle2.ntust.edu.tw/user/edit.php")))
        for address in [
            "https://moodle2.ntust.edu.tw/login/index.php",
            "https://moodle2.ntust.edu.tw/admin/tool/mobile/autologin.php?userid=1&key=k",
            "https://moodle2.ntust.edu.tw/auth/oidc/?source=loginpage",
            "https://i.ntust.edu.tw/",
        ] {
            #expect(!BrowserRouting.isMoodleReturnPage(Self.url(address)))
        }
        #expect(BrowserRouting.isMoodleSignInLink(Self.url("https://moodle2.ntust.edu.tw/admin/tool/mobile/autologin.php")))
    }

    @Test func theHiddenSignInStopsWhereAPasswordIsAskedFor() {
        #expect(BrowserRouting.endsSessionSignIn(Self.url("https://ssoam2.ntust.edu.tw/account/login?ReturnUrl=%2F")))
        #expect(BrowserRouting.endsSessionSignIn(Self.url("https://moodle2.ntust.edu.tw/login/index.php")))
        #expect(BrowserRouting.endsSessionSignIn(Self.url("https://example.com/")))
        #expect(!BrowserRouting.endsSessionSignIn(Self.url("https://ssoam2.ntust.edu.tw/connect/authorize?client_id=x")))
        #expect(!BrowserRouting.endsSessionSignIn(BrowserRouting.webSignInURL))
        #expect(!BrowserRouting.endsSessionSignIn(Self.url("https://moodle2.ntust.edu.tw/my/")))
    }

    private static func cookie(_ name: String, domain: String, secure: Bool = true, value: String = "v") -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: "/"]
        if secure { properties[.secure] = "TRUE" }
        return HTTPCookie(properties: properties)!
    }

    @Test func onlySecureSignInCookiesCrossBetweenTheJarAndTheBrowser() {
        #expect(BrowserRouting.isSharedCookie(Self.cookie("MoodleSession", domain: "moodle2.ntust.edu.tw")))
        #expect(BrowserRouting.isSharedCookie(Self.cookie(".AspNetCore.Identity.Application", domain: "ssoam2.ntust.edu.tw")))
        #expect(BrowserRouting.isSharedCookie(Self.cookie("shared", domain: ".ntust.edu.tw")))
        #expect(!BrowserRouting.isSharedCookie(Self.cookie("MoodleSession", domain: "moodle2.ntust.edu.tw", secure: false)))
        #expect(!BrowserRouting.isSharedCookie(Self.cookie("ASP.NET_SessionId", domain: "courseselection.ntust.edu.tw")))
        #expect(!BrowserRouting.isSharedCookie(Self.cookie("tracker", domain: ".edu.tw")))
        #expect(!BrowserRouting.isSharedCookie(Self.cookie("tracker", domain: "moodle2.ntust.edu.tw.evil.com")))
    }

    @Test func theSchoolJarsSignInCookiesGoInAfterTheSharedJarsSoTheyWin() {
        let identity = ".AspNetCore.Identity.Application"
        let shared = [Self.cookie(identity, domain: "ssoam2.ntust.edu.tw", value: "harvest")]
        let school = [
            Self.cookie(identity, domain: "ssoam2.ntust.edu.tw", value: "school"),
            Self.cookie("ASP.NET_SessionId", domain: "courseselection.ntust.edu.tw"),
        ]
        #expect(BrowserSessionSignIn.sessionCookies(in: [shared, school], for: Self.url("https://moodle2.ntust.edu.tw/my/")).map(\.value) == ["harvest", "school"])
    }

    @Test func aMoodleSessionIsAMoodleSessionCookieWithAValue() {
        #expect(BrowserRouting.hasMoodleSession([Self.cookie("MoodleSession", domain: "moodle2.ntust.edu.tw")]))
        #expect(BrowserRouting.hasMoodleSession([Self.cookie("MoodleSessionprod", domain: ".moodle2.ntust.edu.tw")]))
        #expect(!BrowserRouting.hasMoodleSession([Self.cookie("MoodleSession", domain: "moodle2.ntust.edu.tw", value: "")]))
        #expect(!BrowserRouting.hasMoodleSession([Self.cookie("MoodleSession", domain: "i.ntust.edu.tw")]))
    }

    @Test func moodlesSessionCookieGetsAnExpiryAndKeepsItsFlags() throws {
        let headers = ["Set-Cookie": "MoodleSession=abc; path=/; secure; HttpOnly"]
        let session = try #require(
            HTTPCookie.cookies(withResponseHeaderFields: headers, for: Self.url("https://moodle2.ntust.edu.tw/")).first
        )
        // Whole seconds within the 400 days HTTPCookie allows.
        let expiry = Date(timeIntervalSince1970: (Date.now.timeIntervalSince1970 + 86_400).rounded())
        let lasting = try #require(BrowserRouting.lastingSession(session, until: expiry))
        #expect(lasting.name == "MoodleSession" && lasting.value == "abc")
        #expect(lasting.domain == session.domain && lasting.path == "/")
        #expect(lasting.isSecure && lasting.isHTTPOnly && !lasting.isSessionOnly)
        #expect(lasting.expiresDate == expiry)
    }

    @Test func onlyMoodlesSessionCookieWithoutAnExpiryIsGivenOne() {
        let expiry = Date(timeIntervalSince1970: 2_000_000_000)
        var dated = [HTTPCookiePropertyKey: Any]()
        dated = [.name: "MoodleSession", .value: "v", .domain: "moodle2.ntust.edu.tw", .path: "/", .expires: expiry]
        #expect(BrowserRouting.lastingSession(HTTPCookie(properties: dated)!, until: expiry) == nil)
        #expect(BrowserRouting.lastingSession(Self.cookie("MOODLEID1_", domain: "moodle2.ntust.edu.tw"), until: expiry) == nil)
        #expect(BrowserRouting.lastingSession(Self.cookie("MoodleSession", domain: "i.ntust.edu.tw"), until: expiry) == nil)
    }

    @Test func theLogoutRulesBlockBothLogoutsAndNothingElse() throws {
        let rules = try #require(
            JSONSerialization.jsonObject(with: Data(BrowserPageScripts.logoutRules.utf8)) as? [[String: [String: String]]]
        )
        let filters = try rules.map { rule in
            #expect(rule["action"]?["type"] == "block")
            return try NSRegularExpression(pattern: try #require(rule["trigger"]?["url-filter"]), options: .caseInsensitive)
        }
        func blocked(_ address: String) -> Bool {
            filters.contains { $0.firstMatch(in: address, range: NSRange(address.startIndex..., in: address)) != nil }
        }
        #expect(blocked("https://moodle2.ntust.edu.tw/login/logout.php?sesskey=abc"))
        #expect(blocked("https://moodle2.ntust.edu.tw/auth/oidc/logout.php"))
        #expect(blocked("https://MOODLE2.ntust.edu.tw:443//login/logout.php"))
        #expect(!blocked("https://moodle2.ntust.edu.tw/login/index.php"))
        #expect(!blocked("https://moodle2.ntust.edu.tw/my/?next=/login/logout.php"))
        #expect(!blocked("https://moodle2xntust.edu.tw/login/logout.php"))
    }

    private static let schoolLogouts = [
        "https://interuniversity.ntust.edu.tw/Account/LogOff",
        "https://sso.ntust.edu.tw/login/logout.php",
        "https://suggestionbox.ntust.edu.tw/logout",
        "https://ssoam2.ntust.edu.tw/connect/endsession?id_token_hint=made-up",
        "https://ssoam.ntust.edu.tw/nidp/app/logout",
        "https://ssoam.ntust.edu.tw/AGLogout",
        "https://stu.ntust.edu.tw/stueduneed/Logout.aspx",
        "https://sa02.ntust.edu.tw/classroom_user/sign-out",
        "https://stu.ntust.edu.tw/x/../Logout.aspx",
        "https://SUGGESTIONBOX.ntust.edu.tw./LOGOUT",
        "https://stu.ntust.edu.tw/logout;jsessionid=ABC",
        "https://stu.ntust.edu.tw/app/Logout.do",
        "https://stu.ntust.edu.tw/app/logout.html",
        "http://suggestionbox.ntust.edu.tw/logout",
    ]

    /// Written so only the navigation delegate, which reads the address as the server does, sees them.
    private static let delegateOnlySchoolLogouts = [
        "https://cour01.ntust.edu.tw/DMP_student/%4Cogout.aspx",
        "https://ccdoc.ntust.edu.tw/docmgsystem/index.aspx?action=logout",
        "https://ccdoc.ntust.edu.tw/docmgsystem/index.aspx?Op=Log-Off",
    ]

    /// A school page that only looks like a logout, another site's logout, and Moodle's own pages.
    private static let notSchoolLogouts = [
        "https://stuinfosys.ntust.edu.tw/StudentInformation",
        "https://www.ntust.edu.tw/p/catalogoffice.php",
        "https://ssoam2.ntust.edu.tw/account/login?ReturnUrl=%2Flogout",
        "https://i.ntust.edu.tw/student?q=logout",
        "https://i.ntust.edu.tw/student?action=logouts",
        "https://www.ntust.edu.tw/docs/logout.pdf",
        "https://www.ntust.edu.tw/img/logout.png",
        "https://example.com/logout",
        "https://ntust.edu.tw.evil.com/logout",
        "https://moodle2.ntust.edu.tw/my/?next=/login/logout.php",
    ]

    @Test func aSchoolSitesLogoutIsRefusedHoweverItIsWritten() {
        for address in Self.schoolLogouts + Self.delegateOnlySchoolLogouts {
            let url = Self.url(address)
            #expect(BrowserRouting.isSchoolLogout(url), "\(address)")
            #expect(BrowserRouting.decision(for: url) == .refuse, "\(address)")
            #expect(!BrowserRouting.isSchoolReturnPage(url), "\(address)")
        }
    }

    @Test func aSchoolPageThatOnlyLooksLikeALogoutStillLoads() {
        for address in Self.notSchoolLogouts {
            let url = Self.url(address)
            #expect(!BrowserRouting.isLogout(url), "\(address)")
            if BrowserRouting.isAllowed(url) { #expect(BrowserRouting.decision(for: url) == .load, "\(address)") }
        }
        // Moodle's addresses go by Moodle's own logout rule.
        #expect(!BrowserRouting.isSchoolLogout(Self.url("https://moodle2.ntust.edu.tw/blog/login/logout.php")))
        #expect(BrowserRouting.isLogout(Self.url("https://moodle2.ntust.edu.tw/login/logout.php")))
    }

    @Test func theLogoutRulesBlockTheSchoolsLogoutsAndNotItsPages() throws {
        let rules = try #require(
            JSONSerialization.jsonObject(with: Data(BrowserPageScripts.logoutRules.utf8)) as? [[String: [String: String]]]
        )
        let filters = try rules.map { try NSRegularExpression(pattern: try #require($0["trigger"]?["url-filter"]), options: .caseInsensitive) }
        func blocked(_ address: String) -> Bool {
            filters.contains { $0.firstMatch(in: address, range: NSRange(address.startIndex..., in: address)) != nil }
        }
        for address in Self.schoolLogouts { #expect(blocked(address), "\(address)") }
        for address in Self.notSchoolLogouts { #expect(!blocked(address), "\(address)") }
        #expect(blocked("https://MOODLE2.ntust.edu.tw:443//login/logout.php"))
    }

    @Test func aSchoolSiteSignsInThroughItsOwnRedirectToSSOAndMoodleThroughItsOIDCEntry() {
        let site = Self.url("https://stuinfosys.ntust.edu.tw/StudentInformation")
        let moodle = Self.url("https://moodle2.ntust.edu.tw/my/")
        #expect(BrowserRouting.isSchoolReturnPage(site) && BrowserRouting.isReturnPage(site))
        #expect(!BrowserRouting.isSchoolReturnPage(moodle) && BrowserRouting.isReturnPage(moodle))
        for address in [
            "https://ssoam2.ntust.edu.tw/connect/authorize?client_id=x",
            "https://ssoam.ntust.edu.tw/nidp/app/login",
            "http://stuinfosys.ntust.edu.tw/",
            "https://example.com/",
        ] {
            #expect(!BrowserRouting.isReturnPage(Self.url(address)), "\(address)")
        }
        #expect(BrowserRouting.signInEntry(for: site) == site)
        #expect(BrowserRouting.signInEntry(for: moodle) == BrowserRouting.webSignInURL)
    }

    @Test func aSignInPageGoesBackToThePageItCameInTheWayOf() {
        let school = Self.url("https://stuinfosys.ntust.edu.tw/StudentInformation")
        let moodle = Self.url("https://moodle2.ntust.edu.tw/user/edit.php")
        let ssoForm = Self.url("https://ssoam2.ntust.edu.tw/account/login?ReturnUrl=%2Fconnect%2Fauthorize")
        let moodleForm = Self.url("https://moodle2.ntust.edu.tw/login/index.php")
        #expect(BrowserRouting.signInReturn(for: ssoForm, among: [school, moodle]) == school)
        #expect(BrowserRouting.signInReturn(for: ssoForm, among: [nil, moodle]) == moodle)
        #expect(BrowserRouting.signInReturn(for: ssoForm, among: [ssoForm, nil]) == nil)
        #expect(BrowserRouting.signInReturn(for: moodleForm, among: [school, moodle]) == moodle)
        #expect(BrowserRouting.signInReturn(for: moodleForm, among: [school, nil]) == AppConstants.moodleBaseURL)
        #expect(BrowserRouting.signInReturn(for: school, among: [school, moodle]) == nil)
    }

    /// The portal links several sites by their own sign-in entry, which sends the browser to SSO.
    @Test func thePortalsSignInEntriesAreSchoolPagesThatGoThroughSSO() {
        for address in [
            "https://stu.ntust.edu.tw/Behavior/account/login",
            "https://sa02.ntust.edu.tw/classroom_user/SSO_login.aspx",
            "https://ccdoc.ntust.edu.tw/docmgsystem/login.aspx",
            "https://stu.ntust.edu.tw/stueduneed/stu_login.aspx",
            "https://stu.ntust.edu.tw/exchange_stu/login.aspx",
        ] {
            let url = Self.url(address)
            #expect(BrowserRouting.isSchoolReturnPage(url) && !BrowserRouting.isSSOSignInPage(url), "\(address)")
        }
    }

    @Test func ssosPasswordFormIsTheSchoolSitesSignInPage() {
        #expect(BrowserRouting.isSSOSignInPage(Self.url("https://ssoam2.ntust.edu.tw/Account/Login?ReturnUrl=%2Fconnect%2Fauthorize")))
        #expect(!BrowserRouting.isSSOSignInPage(Self.url("https://ssoam2.ntust.edu.tw/connect/authorize?client_id=x")))
        #expect(!BrowserRouting.isSSOSignInPage(Self.url("https://stuinfosys.ntust.edu.tw/account/login")))
    }

    @Test func theHiddenSignInAlsoStopsAtSsoamsRecaptchaForm() {
        #expect(BrowserRouting.endsSessionSignIn(Self.url("https://ssoam.ntust.edu.tw/nidp/idff/sso?id=x")))
        #expect(!BrowserRouting.endsSessionSignIn(Self.url("https://stuinfosys.ntust.edu.tw/signin-oidc")))
    }

    /// ssoam2 keeps its session in `AuthServer` on `.ntust.edu.tw`, and only a load balancer's
    /// cookie on its own host; `ntustLan`, which the sites set on the domain, is not secure.
    @Test func aSchoolSitesSignInHandsTheBrowserSSOsCookiesItsDomainWideSessionAmongThem() {
        let jars = [
            [Self.cookie("AuthServer", domain: ".ntust.edu.tw", value: "harvest")],
            [
                Self.cookie("AuthServer", domain: ".ntust.edu.tw", value: "school"),
                Self.cookie("BIGipServerpool_ExamSSO_443", domain: "ssoam2.ntust.edu.tw", value: "balancer"),
                Self.cookie("ntustLan", domain: ".ntust.edu.tw", secure: false),
                Self.cookie("MoodleSession", domain: "moodle2.ntust.edu.tw"),
                Self.cookie(".AspNetCore.Cookies", domain: "stuinfosys.ntust.edu.tw"),
                Self.cookie("ASP.NET_SessionId", domain: "courseselection.ntust.edu.tw"),
            ],
        ]
        let site = Self.url("https://stuinfosys.ntust.edu.tw/StudentInformation")
        #expect(BrowserSessionSignIn.sessionCookies(in: jars, for: site).map(\.value) == ["harvest", "school", "balancer"])
        let moodle = BrowserSessionSignIn.sessionCookies(in: jars, for: Self.url("https://moodle2.ntust.edu.tw/my/"))
        #expect(moodle.map(\.name) == ["AuthServer", "AuthServer", "BIGipServerpool_ExamSSO_443", "MoodleSession"])
    }

    @Test func aPageWhoseProcessEndedReloadsOrLoadsItsAddress() {
        let page = Self.url("https://moodle2.ntust.edu.tw/user/edit.php")
        let keyLink = Self.url("https://moodle2.ntust.edu.tw/admin/tool/mobile/autologin.php?key=k")
        #expect(BrowserRouting.pageToRestore(url: page, address: page) == .reload)
        #expect(BrowserRouting.pageToRestore(url: nil, address: page) == .load(page))
        #expect(BrowserRouting.pageToRestore(url: keyLink, address: page) == .load(page))
    }

    @Test @MainActor func aSlowAnswerGivesWayToTheDeadline() async {
        let fast = await BrowserPageScripts.answer(within: .seconds(5)) { 1 }
        #expect(fast == 1)
        let slow = await BrowserPageScripts.answer(within: .milliseconds(50)) { () async -> Int? in
            try? await Task.sleep(for: .seconds(5))
            return 2
        }
        #expect(slow == nil)
    }

    @Test func theLogoutHidingScriptHidesMoodlesByItsOwnRulesAndTheOtherSchoolSitesByTheirWords() {
        let script = BrowserPageScripts.hideLogout
        #expect(script.contains("host === 'moodle2.ntust.edu.tw'"))
        #expect(script.contains(#"/(^|\.)ntust\.edu\.tw$/.test(host)"#))
        #expect(BrowserPageScripts.schoolLogoutSelector.contains(#"a[href*="logoff" i]"#))
        #expect(BrowserPageScripts.schoolLogoutSelector.contains(#"form[action*="sign-out" i]"#))
        #expect(!BrowserPageScripts.schoolLogoutSelector.contains("'"))
        #expect(BrowserPageScripts.logoutSelector.contains(#"a[href^="https://moodle2.ntust.edu.tw/login/logout.php"]"#))
        #expect(BrowserPageScripts.logoutSelector.contains(#"form[action^="/auth/oidc/logout.php"]"#))
        #expect(BrowserPageScripts.leftOverSelector.contains(#".dropdown-divider:has(+ a[href^="/login/logout.php"])"#))
        #expect(!(BrowserPageScripts.logoutSelector + BrowserPageScripts.leftOverSelector).contains("'"))
    }
}
#endif
