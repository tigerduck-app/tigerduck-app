import Testing
@testable import TigerDuck

@MainActor
struct MoreNavigationTests {

    @Test func settingsIsNotReachableThroughMoreFeatureDestination() {
        #expect(!AppFeature.moreFeatures.contains(.settings))
    }

    @Test func moreDoesNotListItself() {
        #expect(!AppFeature.moreFeatures.contains(.more))
    }

    @Test func everyMoreRowHasARealDestination() {
        let destinationsWithRealPages: Set<AppFeature> = [
            .home, .classTable, .calendar, .announcements, .library, .gpa,
            .schoolMail, .emptyClassroom,
        ]
        let unbacked = AppFeature.moreFeatures.filter { !destinationsWithRealPages.contains($0) }
        #expect(unbacked.isEmpty, "More rows with no real destination: \(unbacked)")
    }

    @Test func unpinnedClassTableOpensThroughMore() {
        let route = AppFeature.tabRoute(to: .classTable, visibleTabs: [.home, .calendar])
        #expect(route.tab == .more)
        #expect(route.moreDeepLink == .classTable)
    }

    @Test func pinnedFeatureOpensItsOwnTab() {
        let route = AppFeature.tabRoute(to: .classTable, visibleTabs: [.home, .classTable])
        #expect(route.tab == .classTable)
        #expect(route.moreDeepLink == nil)
    }

    @Test func removingEveryTabFallsBackToMore() {
        #expect(AppFeature.selection(.home, keptOn: []) == .more)
    }

    @Test func removingTheSelectedTabSelectsTheFirstOneLeft() {
        #expect(AppFeature.selection(.calendar, keptOn: [.classTable, .home]) == .classTable)
        #expect(AppFeature.selection(.home, keptOn: [.classTable, .home]) == .home)
        #expect(AppFeature.selection(.more, keptOn: [.classTable]) == .more)
    }
}
