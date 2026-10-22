#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct WhatsNewSchoolMailPagesTests {
    @Test func onlyCalendarChanges() {
        #expect(WhatsNewPage.recommendedTabsWithMail([.home, .classTable, .announcements, .calendar])
            == [.home, .classTable, .announcements, .schoolMail])
    }

    @Test func mailTakesCalendarsSlot() {
        #expect(WhatsNewPage.recommendedTabsWithMail([.home, .classTable, .calendar])
            == [.home, .classTable, .schoolMail])
        #expect(WhatsNewPage.recommendedTabsWithMail([.calendar, .home, .gpa, .announcements])
            == [.schoolMail, .home, .gpa, .announcements])
    }

    @Test func withoutCalendarMailIsAppendedWhenThereIsRoom() {
        #expect(WhatsNewPage.recommendedTabsWithMail([.home, .classTable])
            == [.home, .classTable, .schoolMail])
        #expect(WhatsNewPage.recommendedTabsWithMail([.home, .classTable, .gpa])
            == [.home, .classTable, .gpa, .schoolMail])
    }

    @Test func aFullBarWithoutCalendarIsNotAsked() {
        #expect(WhatsNewPage.recommendedTabsWithMail([.home, .classTable, .gpa, .announcements]) == nil)
    }

    @Test func aBarThatAlreadyHasMailIsNotAsked() {
        #expect(WhatsNewPage.recommendedTabsWithMail([.home, .schoolMail, .calendar]) == nil)
        #expect(WhatsNewPage.recommendedTabsWithMail([.home, .schoolMail]) == nil)
    }

    @Test func aBarWithoutMailGetsTheMailPages() {
        #expect(WhatsNewPage.offersMailPages(configuredTabs: [.home, .classTable, .calendar]))
        #expect(WhatsNewPage.offersMailPages(configuredTabs: [.home, .announcements, .gpa, .library]))
    }

    @Test func aBarThatAlreadyHasMailSkipsTheMailPages() {
        #expect(!WhatsNewPage.offersMailPages(configuredTabs: AppFeature.defaultTabs))
        #expect(!WhatsNewPage.offersMailPages(configuredTabs: [.home, .gpa, .schoolMail, .calendar]))
        #expect(WhatsNewPage.recommendedTabsWithMail([.home, .gpa, .schoolMail, .calendar]) == nil)
    }

    @Test func applyingSwapsOnlyCalendarForMail() {
        let bar = StandInBar([.home, .classTable, .announcements, .calendar])
        #expect(WhatsNewPage.asksAboutMail(bar))

        WhatsNewPage.applyMailRecommendation(to: bar)
        #expect(bar.configuredTabs == [.home, .classTable, .announcements, .schoolMail])

        #expect(!WhatsNewPage.asksAboutMail(bar))
        WhatsNewPage.applyMailRecommendation(to: bar)
        #expect(bar.configuredTabs == [.home, .classTable, .announcements, .schoolMail])
    }

    @Test func applyingAddsMailLeftOfMoreWhenThereIsRoom() {
        let bar = StandInBar([.home, .gpa])
        WhatsNewPage.applyMailRecommendation(to: bar)
        #expect(bar.configuredTabs == [.home, .gpa, .schoolMail])
    }

    @Test func aFullBarWithoutCalendarIsNeitherAskedNorChanged() {
        let full: [AppFeature] = [.home, .classTable, .gpa, .announcements]
        let bar = StandInBar(full)
        #expect(!WhatsNewPage.asksAboutMail(bar))
        WhatsNewPage.applyMailRecommendation(to: bar)
        #expect(bar.configuredTabs == full)
    }

    @Test func theMailPagesAreRegisteredFor230() throws {
        let pages = try #require(WhatsNewCatalog.releases["2.3.0"])
        #expect(pages.map(\.id) == ["school-mail", "mail-bottom-bar"])
    }

    @Test func everyUpgradeMeetsMailAndTheBarQuestion() throws {
        #expect(try pageIDs(upgradingFrom: "2.1.4") == ["school-mail", "mail-bottom-bar"])
        #expect(try pageIDs(upgradingFrom: "2.2.0") == ["school-mail", "mail-bottom-bar"])
    }

    private func pageIDs(upgradingFrom lastSeen: String) throws -> [String] {
        let current = try #require(AppVersion("2.3.0"))
        let flow = try #require(WhatsNewFlowBuilder.upgrade(
            from: AppVersion(lastSeen),
            to: current,
            version: "2.3.0",
            language: .en,
            releases: WhatsNewCatalog.releases,
            summary: nil,
            isApplicable: { _ in true }
        ))
        return flow.pages.map(\.id)
    }
}

@MainActor
private final class StandInBar: WhatsNewBottomBarState {
    var configuredTabs: [AppFeature]

    init(_ configuredTabs: [AppFeature]) {
        self.configuredTabs = configuredTabs
    }
}
#endif
