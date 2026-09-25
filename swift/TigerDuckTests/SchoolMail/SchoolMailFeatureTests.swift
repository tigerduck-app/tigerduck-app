#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct SchoolMailFeatureTests {
    @Test func schoolMailIsAPageFeature() {
        #expect(AppFeature(rawValue: "schoolMail") == .schoolMail)
        #expect(AppFeature.schoolMail.category == .page)
        #expect(AppFeature.schoolMail.iconName == "envelope.fill")
        #expect(AppFeature.schoolMail.isImplemented)  // DEBUG build
        #expect(AppFeature.moreFeatures.contains(.schoolMail))
        #expect(AppFeature.pinnableFeatures.contains(.schoolMail))
        #expect(!AppFeature.defaultTabs.contains(.schoolMail))
    }

    @Test func schoolMailIsLastInThePageSection() {
        let pageFeatures = AppFeature.moreFeatures.filter { $0.category == .page }
        #expect(pageFeatures.last == .schoolMail)
        #expect(pageFeatures == [.home, .classTable, .calendar, .schoolMail])
    }

    @Test func storedTabsWithSchoolMailDecode() throws {
        let data = try JSONEncoder().encode([AppFeature.home, .schoolMail])
        #expect(try JSONDecoder().decode([AppFeature].self, from: data) == [.home, .schoolMail])
    }

    @Test func mailNotificationsRouteToTheMessage() {
        let link = AppState.schoolMailDeepLink(from: ["kind": "school_mail", "folder": "INBOX", "uid": 42])
        #expect(link == .schoolMail(folder: "INBOX", uid: 42))
    }

    @Test func summaryAndSignInNotificationsOpenTheList() {
        #expect(AppState.schoolMailDeepLink(from: ["kind": "school_mail"]) == .schoolMail(folder: "INBOX", uid: nil))
        #expect(AppState.schoolMailDeepLink(from: ["kind": "custom_push_bulletin"]) == nil)
    }

    @Test func uidParsesFromADoubleTaggedNSNumber() {
        // NSNumber(value: 42.0)'s objCType is 'd' (double); `as? Int` fails on it the same way
        // TigerDuckApp's bulletinId(from:) doc comment describes for bulletin_id.
        let link = AppState.schoolMailDeepLink(from: ["kind": "school_mail", "uid": NSNumber(value: 42.0)])
        #expect(link == .schoolMail(folder: "INBOX", uid: 42))
    }

    @Test func uidParsesFromADecimalString() {
        let link = AppState.schoolMailDeepLink(from: ["kind": "school_mail", "uid": "42"])
        #expect(link == .schoolMail(folder: "INBOX", uid: 42))
    }

    @Test func outOfRangeOrNonNumericUIDOpensTheList() {
        #expect(AppState.schoolMailDeepLink(from: ["kind": "school_mail", "uid": "-1"]) == .schoolMail(folder: "INBOX", uid: nil))
        #expect(AppState.schoolMailDeepLink(from: ["kind": "school_mail", "uid": "not-a-number"]) == .schoolMail(folder: "INBOX", uid: nil))
        #expect(AppState.schoolMailDeepLink(from: ["kind": "school_mail", "uid": "99999999999"]) == .schoolMail(folder: "INBOX", uid: nil))
    }

    // MARK: Which schemes a tapped link may be opened with

    @Test(arguments: [
        "https://ntust.edu.tw/", "http://ntust.edu.tw/", "HTTPS://ntust.edu.tw/",
        "mailto:someone@mail.ntust.edu.tw", "MailTo:someone@mail.ntust.edu.tw",
    ])
    func theAllowedSchemesOpen(href: String) {
        #expect(MailLinkTarget.isOpenable(href))
    }

    /// `MailWarnings.canonicalHref` hands back anything that is not http(s) unchanged, so every
    /// one of these used to be offered with an Open button. `tigerduck:` is the pointed one: it
    /// would have let a mail drive the app's own deep links from a single confirmed tap.
    @Test(arguments: [
        "tigerduck://schoolMail?uid=1", "javascript:alert(1)", "file:///etc/passwd",
        "data:text/html,<b>x</b>", "sms:+886000000000", "itms-apps://apps.apple.com/app/id1",
        "", "ntust.edu.tw", "/relative/path", "//ntust.edu.tw/x", "1https://ntust.edu.tw/",
    ])
    func everythingElseIsNotOpenable(href: String) {
        #expect(!MailLinkTarget.isOpenable(href))
    }

    /// A colon inside a path or userinfo is not a scheme separator.
    @Test func aColonThatIsNotASchemeSeparatorIsNotAScheme() {
        #expect(!MailLinkTarget.isOpenable("ntust.edu.tw/a:b"))
        #expect(MailLinkTarget.isOpenable("https://user:secret@ntust.edu.tw/"))
    }

}
#endif
