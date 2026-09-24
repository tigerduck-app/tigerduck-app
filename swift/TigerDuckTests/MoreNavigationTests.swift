import Testing
@testable import TigerDuck

/// `MoreView` hides the back chevron on everything it pushes through its
/// `AppFeature` navigation destination (see `MoreFeatureDestination`).
///
/// That treatment is correct only for feature pages. Settings must keep its
/// chevron, and it does so purely because it can never reach that
/// destination — it is pushed by its own `NavigationLink`, and
/// `moreFeatures` filters on `isImplemented`, which `.settings` fails. That
/// is an implicit, action-at-a-distance guarantee: flipping
/// `AppFeature.settings.isImplemented` to `true` for some unrelated reason
/// would silently strip Settings' back button. These tests make that
/// failure loud.
struct MoreNavigationTests {

    @Test func settingsIsNotReachableThroughMoreFeatureDestination() {
        // If this fails, Settings has started rendering as a More row and
        // will be pushed chevron-less. Give it an explicit route that
        // bypasses MoreFeatureDestination before changing this expectation.
        #expect(!AppFeature.moreFeatures.contains(.settings))
    }

    @Test func moreDoesNotListItself() {
        // A `.more` row would push the More tab onto its own stack with no
        // chevron to escape it.
        #expect(!AppFeature.moreFeatures.contains(.more))
    }

    @Test func everyMoreRowHasARealDestination() {
        // `moreDestination(for:)` falls through to `PlaceholderFeatureView`
        // for anything it does not name. A placeholder is fine to reach by
        // accident when it has a back button; reaching one that is also
        // chevron-less is a dead end. Every row that can be tapped should
        // map to a real page.
        let destinationsWithRealPages: Set<AppFeature> = [
            .home, .classTable, .calendar, .announcements, .library, .gpa,
        ]
        let unbacked = AppFeature.moreFeatures.filter { !destinationsWithRealPages.contains($0) }
        #expect(unbacked.isEmpty, "More rows with no real destination: \(unbacked)")
    }
}
