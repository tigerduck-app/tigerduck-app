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
        #expect(BrowserSessionSignIn.sessionCookies(in: [shared, school]).map(\.value) == ["harvest", "school"])
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

    @Test func aPageWhoseProcessEndedReloadsOrLoadsItsAddress() {
        let page = Self.url("https://moodle2.ntust.edu.tw/user/edit.php")
        let keyLink = Self.url("https://moodle2.ntust.edu.tw/admin/tool/mobile/autologin.php?key=k")
        #expect(BrowserNavigator.pageToRestore(url: page, address: page) == nil)
        #expect(BrowserNavigator.pageToRestore(url: nil, address: page) == page)
        #expect(BrowserNavigator.pageToRestore(url: keyLink, address: page) == page)
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

    @Test func theLogoutHidingScriptRunsOnMoodleOnlyAndHidesLinksAndForms() {
        let script = BrowserPageScripts.hideLogout
        #expect(script.contains("location.hostname !== 'moodle2.ntust.edu.tw'"))
        #expect(BrowserPageScripts.logoutSelector.contains(#"a[href^="https://moodle2.ntust.edu.tw/login/logout.php"]"#))
        #expect(BrowserPageScripts.logoutSelector.contains(#"form[action^="/auth/oidc/logout.php"]"#))
        #expect(BrowserPageScripts.leftOverSelector.contains(#".dropdown-divider:has(+ a[href^="/login/logout.php"])"#))
        #expect(!(BrowserPageScripts.logoutSelector + BrowserPageScripts.leftOverSelector).contains("'"))
    }
}
#endif
