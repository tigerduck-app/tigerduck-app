#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

struct LinkRoutingTests {
    private static func url(_ text: String) -> URL { URL(string: text)! }

    private static func destination(
        _ url: URL, installed: Bool = false, _ preference: BrowserPreference
    ) -> LinkRouting.Destination {
        LinkRouting.destination(for: url, moodleAppInstalled: installed, preference: preference)
    }

    @Test(arguments: [
        "https://tigerduck.app",
        "https://github.com/tigerduck-app/tigerduck-app/issues",
        "https://moodle2.ntust.edu.tw/course/view.php?id=7",
        "HTTPS://www.ntust.edu.tw/",
    ])
    func aWebPageOpensWhereTheSettingSays(_ address: String) {
        let page = Self.url(address)
        #expect(Self.destination(page, .inApp) == .browser(page))
        #expect(Self.destination(page, .system) == .system(page))
    }

    @Test(arguments: [
        "http://www.ntust.edu.tw/",
        "https://apps.apple.com/app/id6740000000",
        "mailto:someone@mail.ntust.edu.tw",
        "tel:+886227333141",
        "app-settings:",
        "itms-apps://apps.apple.com/app/id6740000000",
        "tigerduck://classtable",
    ])
    func otherLinksStayWithTheSystem(_ address: String) {
        let link = Self.url(address)
        for preference in BrowserPreference.allCases {
            #expect(Self.destination(link, preference) == .system(link))
        }
    }

    @Test(arguments: [
        ("/course/view.php?id=7", "https://moodle2.ntust.edu.tw/course/view.php?id=7"),
        ("/mod/assign/view.php?id=12345&action=grading", "https://moodle2.ntust.edu.tw/mod/assign/view.php?id=12345&action=grading"),
        ("/my/", "https://moodle2.ntust.edu.tw/my/"),
    ])
    func aMoodleLinkOpensTheBrowserWithoutTheMoodleApp(path: String, page: String) throws {
        let link = try #require(AppConstants.moodleDeepLink(redirectingTo: path))
        for preference in BrowserPreference.allCases {
            #expect(Self.destination(link, installed: false, preference) == .browser(Self.url(page)))
            #expect(Self.destination(link, installed: true, preference) == .system(link))
        }
    }

    @Test(arguments: [
        "moodlemobile://https://moodle2.ntust.edu.tw",
        "moodlemobile://https://moodle2.ntust.edu.tw?redirect=//evil.example/",
        "moodlemobile://https://moodle2.ntust.edu.tw?redirect=https://evil.example/",
    ])
    func aMoodleLinkWithNoMoodlePageStaysWithTheSystem(_ address: String) {
        let link = Self.url(address)
        #expect(Self.destination(link, installed: false, .inApp) == .system(link))
    }
}
#endif
