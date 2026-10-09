// The 2.3.0 School Mail What's New pages: the "recommended arrangement" puts Mail in Calendar's
// slot, else appends it if there is room, else offers nothing. A bar with Mail skips both pages.
// iPhone/iPad-only like the pages; the test target also builds for macOS.
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

    @Test func aHiddenLibraryTabDoesNotTakeASlot() {
        let visible = AppFeature.visibleTabs([.home, .classTable, .gpa, .library], libraryEnabled: false)
        #expect(WhatsNewPage.recommendedTabsWithMail(visible) == [.home, .classTable, .gpa, .schoolMail])
    }

    @Test func aBarWithoutMailGetsTheMailPages() {
        #expect(WhatsNewPage.offersMailPages(configuredTabs: [.home, .classTable, .calendar]))
        #expect(WhatsNewPage.offersMailPages(configuredTabs: [.home, .announcements, .gpa, .library]))
    }

    /// Both the introduction and the bottom-bar question stay out.
    @Test func aBarThatAlreadyHasMailSkipsTheMailPages() {
        #expect(!WhatsNewPage.offersMailPages(configuredTabs: AppFeature.defaultTabs))
        #expect(!WhatsNewPage.offersMailPages(configuredTabs: [.home, .gpa, .schoolMail, .calendar]))
        #expect(WhatsNewPage.recommendedTabsWithMail([.home, .gpa, .schoolMail, .calendar]) == nil)
    }

    // MARK: - Apply, on a stand-in for `AppState`

    @Test func applyingSwapsOnlyCalendarForMail() {
        let bar = StandInBar([.home, .classTable, .announcements, .calendar])
        #expect(WhatsNewPage.asksAboutMail(bar))

        WhatsNewPage.applyMailRecommendation(to: bar)
        #expect(bar.configuredTabs == [.home, .classTable, .announcements, .schoolMail])

        // Back, then Apply again: nothing left to change.
        #expect(!WhatsNewPage.asksAboutMail(bar))
        WhatsNewPage.applyMailRecommendation(to: bar)
        #expect(bar.configuredTabs == [.home, .classTable, .announcements, .schoolMail])
    }

    @Test func applyingAddsMailLeftOfMoreWhenThereIsRoom() {
        let bar = StandInBar([.home, .gpa])
        WhatsNewPage.applyMailRecommendation(to: bar)
        #expect(bar.configuredTabs == [.home, .gpa, .schoolMail])
    }

    /// Keep Mine calls nothing, so a bar the question skips must not
    /// change even if Apply were reached.
    @Test func aFullBarWithoutCalendarIsNeitherAskedNorChanged() {
        let full: [AppFeature] = [.home, .classTable, .gpa, .announcements]
        let bar = StandInBar(full)
        #expect(!WhatsNewPage.asksAboutMail(bar))
        WhatsNewPage.applyMailRecommendation(to: bar)
        #expect(bar.configuredTabs == full)
    }

    @Test func aHiddenLibraryTabLeavesRoomForMail() {
        let bar = StandInBar([.home, .classTable, .gpa, .library], libraryEnabled: false)
        #expect(WhatsNewPage.asksAboutMail(bar))
        WhatsNewPage.applyMailRecommendation(to: bar)
        #expect(bar.configuredTabs == [.home, .classTable, .gpa, .schoolMail])
    }

    // MARK: - Registration

    @Test func theMailPagesAreRegisteredFor230() throws {
        let pages = try #require(WhatsNewCatalog.releases["2.3.0"])
        #expect(pages.map(\.id) == ["school-mail", "mail-bottom-bar"])
    }

    /// Both upgrade paths get the same two pages.
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

/// The bar's slice of `AppState`, without the Keychain and migrations its
/// init brings along.
@MainActor
private final class StandInBar: WhatsNewBottomBarState {
    var configuredTabs: [AppFeature]
    let libraryFeatureEnabled: Bool

    init(_ configuredTabs: [AppFeature], libraryEnabled: Bool = true) {
        self.configuredTabs = configuredTabs
        self.libraryFeatureEnabled = libraryEnabled
    }
}
#endif
