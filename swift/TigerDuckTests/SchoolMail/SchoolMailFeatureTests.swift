#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct SchoolMailFeatureTests {
    @Test func schoolMailIsAnAcademicFeature() {
        #expect(AppFeature(rawValue: "schoolMail") == .schoolMail)
        #expect(AppFeature.schoolMail.category == .academic)
        #expect(AppFeature.schoolMail.iconName == "envelope.fill")
        #expect(AppFeature.schoolMail.isImplemented)  // DEBUG build
        #expect(AppFeature.moreFeatures.contains(.schoolMail))
        #expect(AppFeature.pinnableFeatures.contains(.schoolMail))
        #expect(!AppFeature.defaultTabs.contains(.schoolMail))
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
}
#endif
