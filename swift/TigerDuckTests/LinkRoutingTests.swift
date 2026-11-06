#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

struct LinkRoutingTests {
    private static func url(_ text: String) -> URL { URL(string: text)! }

    @Test(arguments: [
        "https://moodle2.ntust.edu.tw/course/view.php?id=7",
        "https://moodle2.ntust.edu.tw/pluginfile.php/123/mod_resource/content/1/week1.pdf",
        "https://webmail.ntust.edu.tw/",
        "HTTPS://www.ntust.edu.tw/p/406-1000-1.php",
    ])
    func aSchoolPageOpensInTheBrowser(_ address: String) {
        let page = Self.url(address)
        for target in MoodleOpenTarget.allCases {
            #expect(LinkRouting.destination(for: page, moodleAppInstalled: false, moodleOpenTarget: target) == .browser(page))
            #expect(LinkRouting.destination(for: page, moodleAppInstalled: true, moodleOpenTarget: target) == .browser(page))
        }
    }

    @Test(arguments: [
        "https://tigerduck.app",
        "https://github.com/tigerduck-app/tigerduck-app/issues",
        "https://status.tigerduck.app/",
        "https://ntust.edu.tw.evil.com/",
        "http://www.ntust.edu.tw/",
        "https://moodle2.ntust.edu.tw/login/logout.php?sesskey=abc",
        "https://apps.apple.com/app/id6740000000",
        "mailto:someone@mail.ntust.edu.tw",
        "tel:+886227333141",
        "app-settings:",
        "tigerduck://classtable",
    ])
    func anyOtherLinkGoesToTheSystem(_ address: String) {
        let link = Self.url(address)
        #expect(LinkRouting.destination(for: link, moodleAppInstalled: false, moodleOpenTarget: .app) == .system(link))
    }

    @Test(arguments: [
        ("/course/view.php?id=7", "https://moodle2.ntust.edu.tw/course/view.php?id=7"),
        ("/mod/assign/view.php?id=12345&action=grading", "https://moodle2.ntust.edu.tw/mod/assign/view.php?id=12345&action=grading"),
        ("/my/", "https://moodle2.ntust.edu.tw/my/"),
    ])
    func aMoodleLinkOpensWhereTheSettingSaysWhileTheAppIsInstalled(path: String, page: String) throws {
        let link = try #require(AppConstants.moodleDeepLink(redirectingTo: path))
        let inBrowser = LinkRouting.Destination.browser(Self.url(page))
        #expect(LinkRouting.destination(for: link, moodleAppInstalled: true, moodleOpenTarget: .app) == .system(link))
        #expect(LinkRouting.destination(for: link, moodleAppInstalled: true, moodleOpenTarget: .browser) == inBrowser)
        #expect(LinkRouting.destination(for: link, moodleAppInstalled: false, moodleOpenTarget: .app) == inBrowser)
        #expect(LinkRouting.destination(for: link, moodleAppInstalled: false, moodleOpenTarget: .browser) == inBrowser)
    }

    @Test(arguments: [
        "moodlemobile://https://moodle2.ntust.edu.tw",
        "moodlemobile://https://moodle2.ntust.edu.tw?redirect=//evil.example/",
        "moodlemobile://https://moodle2.ntust.edu.tw?redirect=https://evil.example/",
    ])
    func aMoodleLinkWithNoMoodlePageStaysWithTheSystem(_ address: String) {
        let link = Self.url(address)
        for target in MoodleOpenTarget.allCases {
            #expect(LinkRouting.destination(for: link, moodleAppInstalled: false, moodleOpenTarget: target) == .system(link))
        }
    }

    @MainActor @Test func aMoodleFileLinkFromTheWebServiceOpensSignedInInTheBrowser() {
        let link = Self.url("https://moodle2.ntust.edu.tw/webservice/pluginfile.php/123/mod_forum/attachment/4/notes.docx?token=t0k")
        let page = Self.url("https://moodle2.ntust.edu.tw/pluginfile.php/123/mod_forum/attachment/4/notes.docx")
        #expect(LinkRouting.destination(for: MoodlePage.browserURL(link), moodleAppInstalled: false, moodleOpenTarget: .app) == .browser(page))
    }
}
#endif
