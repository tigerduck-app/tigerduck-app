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
}
#endif
