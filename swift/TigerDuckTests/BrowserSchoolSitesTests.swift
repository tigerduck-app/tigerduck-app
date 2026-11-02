#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

struct BrowserSchoolSitesTests {
    private static func url(_ text: String) -> URL { URL(string: text)! }

    private static func cookie(_ name: String, _ domain: String, size: Int = 1, path: String = "/") -> HTTPCookie {
        HTTPCookie(properties: [
            .name: name, .value: String(repeating: "v", count: size), .domain: domain, .path: path, .secure: "TRUE",
        ])!
    }

    private static let stuinfosys = "stuinfosys.ntust.edu.tw"
    /// stuinfosys's apps each keep a chunked session of about 4.5 KB on the host's whole path, next
    /// to SSO's domain-wide one and the OIDC nonce a sign-in that did not finish leaves.
    private static func session(_ app: String) -> [HTTPCookie] {
        [cookie(app, stuinfosys, size: 10), cookie(app + "C1", stuinfosys, size: 3990), cookie(app + "C2", stuinfosys, size: 520)]
    }

    private static let sso = cookie("AuthServer", ".ntust.edu.tw", size: 1730)
    private static let nonce = cookie("OpenIdConnect.nonce.a%2Bb%3D", stuinfosys, size: 330)
    private static let elsewhere = [
        cookie(".AspNet.CookiesC1", "cour01.ntust.edu.tw", size: 3000),
        cookie("QueryCourseC1", "querycourse.ntust.edu.tw", size: 3990, path: "/QueryCourse"),
    ]

    @Test func threeAppsOnOneHostDropThatHostsCookiesAndKeepSSOs() {
        let jar = [Self.sso, Self.nonce] + Self.session("JudgeCourseServ") + Self.session("StuScoreQueryServ") + Self.elsewhere
        let dropped = BrowserSchoolSites.cookiesToDrop(from: jar, opening: Self.url("https://stuinfosys.ntust.edu.tw/StudentInformation"))

        let sessions = ["JudgeCourseServ", "StuScoreQueryServ"].flatMap { [$0, $0 + "C1", $0 + "C2"] }
        #expect(Set(dropped.map(\.name)) == Set(sessions + ["OpenIdConnect.nonce.a%2Bb%3D"]))
        #expect(dropped.allSatisfy { $0.domain == Self.stuinfosys })
    }

    @Test func oneAppsSessionStays() {
        let jar = [Self.sso, Self.nonce] + Self.session(".AspNet.Cookies") + Self.elsewhere
        #expect(BrowserSchoolSites.cookiesToDrop(from: jar, opening: Self.url("https://StuInfoSys.ntust.edu.tw/ThesisAdvisor")).isEmpty)
    }

    @Test func onlyTheCookiesAPageIsSentCount() {
        let path = [Self.sso] + (1 ... 3).map { Self.cookie("QueryCourseC\($0)", "querycourse.ntust.edu.tw", size: 3990, path: "/QueryCourse") }
        #expect(BrowserSchoolSites.cookiesToDrop(from: path, opening: Self.url("https://querycourse.ntust.edu.tw/")).isEmpty)
        #expect(BrowserSchoolSites.cookiesToDrop(from: path, opening: Self.url("https://querycourse.ntust.edu.tw/QueryCourse/")).count == 3)

        let otherHosts = [Self.sso] + Self.session("A") + Self.session("B")
        #expect(BrowserSchoolSites.cookiesToDrop(from: otherHosts, opening: Self.url("https://sa.ntust.edu.tw/Dorm/")).isEmpty)
        #expect(BrowserSchoolSites.cookiesToDrop(from: otherHosts, opening: Self.url("https://stuinfosys.ntust.edu.tw")).count == 6)
    }

    @Test func courseQueryOpensThroughItsSignInButtonsAddress() {
        let link = BrowserSchoolSites.signInLink(for: Self.url("https://querycourse.ntust.edu.tw/QueryCourse/"))
        #expect(link?.absoluteString
            == "https://querycourse.ntust.edu.tw/QueryCourse/api//OAuth2/Login?returnUrl=https%3A%2F%2Fquerycourse.ntust.edu.tw%2FQueryCourse%2F")
    }

    @Test func counselingOpensThroughItsSignInLink() {
        #expect(BrowserSchoolSites.signInLink(for: Self.url("https://sa02.ntust.edu.tw/WebCounseling/"))
            == Self.url("https://sa02.ntust.edu.tw/WebCounseling/OAuth2/Login"))
    }

    @Test func theDormitorySystemOpensThroughItsSignInLink() {
        #expect(BrowserSchoolSites.signInLink(for: Self.url("https://sa.ntust.edu.tw/Dorm/"))
            == Self.url("https://sa.ntust.edu.tw/Dorm/OAuth2/Login"))
        #expect(BrowserSchoolSites.signInLink(for: Self.url("https://sa.ntust.edu.tw/Scholarship/")) == nil)
    }

    @Test(arguments: [
        "https://sa02.ntust.edu.tw/WebCounseling/Front_Index/FrontIndex/Index",
        "https://sa02.ntust.edu.tw/classroom_user/SSO_login.aspx",
        "https://querycourse.ntust.edu.tw/QueryCourse/Report.aspx",
        "https://querycourse.ntust.edu.tw/QueryCourse/?CourseNo=CS1001",
        "http://querycourse.ntust.edu.tw/QueryCourse/",
        "https://querycourse.ntust.edu.tw.example.com/QueryCourse/",
        "https://stuinfosys.ntust.edu.tw/StudentInformation",
    ])
    func otherPagesOpenAsTheyAre(_ address: String) {
        #expect(BrowserSchoolSites.signInLink(for: Self.url(address)) == nil)
    }

    @Test func theResearchEthicsAndSocialPracticeSignInsAreFilledByTheirFieldsNames() {
        let form = BrowserSchoolSites.SignInForm(studentId: "UserName", password: "Password")
        #expect(BrowserSchoolSites.signInForm(at: Self.url("https://stuinfosys.ntust.edu.tw/Authenticate/Account/EnrollStudent/ethicscourse")) == form)
        #expect(BrowserSchoolSites.signInForm(at: Self.url("https://StuInfoSys.ntust.edu.tw/Authenticate/SSOAccount/Index/SSOcgesocial?x=1")) == form)
    }

    @Test func theStudentCardSignInIsFilledByItsFieldsNames() {
        #expect(BrowserSchoolSites.signInForm(at: Self.url("https://cardsystem.ntust.edu.tw/std/index.php/user/login"))
            == BrowserSchoolSites.SignInForm(studentId: "id", password: "password"))
        #expect(BrowserSchoolSites.signInForm(at: Self.url("https://cardsystem.ntust.edu.tw/std/index.php/user/agreement")) == nil)
    }

    @Test func theWorkStudySignInIsFilledByItsFieldsNames() {
        let form = BrowserSchoolSites.SignInForm(studentId: "studentno", password: "password")
        #expect(BrowserSchoolSites.signInForm(at: Self.url("https://studentpay.ntust.edu.tw/")) == form)
        #expect(BrowserSchoolSites.signInForm(at: Self.url("https://studentpay.ntust.edu.tw")) == nil)
        #expect(BrowserSchoolSites.signInForm(at: Self.url("https://studentpay.ntust.edu.tw/Default.aspx")) == nil)
    }

    @Test func theSuggestionBoxSignInIsFilledByItsFieldsNames() {
        #expect(BrowserSchoolSites.signInForm(at: Self.url("https://suggestionbox.ntust.edu.tw/login"))
            == BrowserSchoolSites.SignInForm(studentId: "account", password: "password"))
        #expect(BrowserSchoolSites.signInForm(at: Self.url("https://suggestionbox.ntust.edu.tw/")) == nil)
    }

    @Test(arguments: [
        "http://stuinfosys.ntust.edu.tw/Authenticate/Account/EnrollStudent/ethicscourse",
        "https://stuinfosys.ntust.edu.tw:8443/Authenticate/Account/EnrollStudent/ethicscourse",
        "https://user@stuinfosys.ntust.edu.tw/Authenticate/Account/EnrollStudent/ethicscourse",
        "https://stuinfosys.ntust.edu.tw/authenticate/account/enrollstudent/ethicscourse",
        "https://stuinfosys.ntust.edu.tw/Authenticate/Account/EnrollStudent/ethicscourse/",
        "https://stuinfosys.ntust.edu.tw/Authenticate/Account/EnrollStudent",
        "https://ssoam2.ntust.edu.tw/account/login",
    ])
    func noOtherAddressIsFilled(_ address: String) {
        #expect(BrowserSchoolSites.signInForm(at: Self.url(address)) == nil)
    }
}
#endif
