import Testing
@testable import TigerDuck

/// `MoreView` hides the back chevron on everything it pushes through its
/// `AppFeature` navigation destination (see `MoreFeatureDestination`).
///
/// That is right only for feature pages. Settings keeps its chevron only
/// because it never reaches that destination: it is pushed by its own
/// `NavigationLink`, and `moreFeatures` filters on `isImplemented`, which
/// `.settings` fails. Setting `AppFeature.settings.isImplemented` to `true`
/// would silently strip Settings' back button; these tests make that loud.
@MainActor
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
        // `moreDestination(for:)` falls through to `PlaceholderFeatureView` for anything it
        // does not name. A placeholder pushed without a chevron is a dead end, so every row
        // that can be tapped must map to a real page.
        let destinationsWithRealPages: Set<AppFeature> = [
            .home, .classTable, .calendar, .announcements, .library, .gpa,
            .schoolMail,
        ]
        let unbacked = AppFeature.moreFeatures.filter { !destinationsWithRealPages.contains($0) }
        #expect(unbacked.isEmpty, "More rows with no real destination: \(unbacked)")
    }
}
