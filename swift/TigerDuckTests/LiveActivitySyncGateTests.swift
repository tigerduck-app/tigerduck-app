// Live Activity must be unavailable while course sync (`cloudSyncEnabled`,
// 同步課程資訊) is off — the app's own footnote
// (`sync_courses_footer_platform_note`) already promises this. Spec §6.
//
// `effectiveLiveActivityEnabled` is the one place that combined answer is
// computed; `LiveActivityScenarioResolver.resolve` is the reader covered
// here, without constructing `AppState`, which this test target cannot do.
// The schedule upload's reading is pinned in `ScheduleSyncServiceTests`, the
// coordinator's in `LiveActivityCoordinatorTests`.
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct LiveActivitySyncGateTests {

    private static let now = Date(timeIntervalSince1970: 1_757_500_000)

    /// An assignment due soon enough to qualify as the urgent scenario under
    /// the store's default 8-hour lead time, so `resolve` would return a
    /// non-nil snapshot whenever Live Activity is available. No course is
    /// needed: the assignment scenario is checked before any class scenario
    /// and does not require one to resolve.
    private static func urgentAssignment() -> SDAssignment {
        SDAssignment(
            assignmentId: "a1",
            courseNo: "CS101",
            courseName: "Test Course",
            title: "Homework",
            dueDate: now.addingTimeInterval(3600)
        )
    }

    // MARK: - The effective rule itself

    @Test("the effective rule is both switches ANDed — all four combinations")
    func allFourCombinations() {
        #expect(effectiveLiveActivityEnabled(isLiveActivityEnabled: true, cloudSyncEnabled: true) == true)
        #expect(effectiveLiveActivityEnabled(isLiveActivityEnabled: true, cloudSyncEnabled: false) == false)
        #expect(effectiveLiveActivityEnabled(isLiveActivityEnabled: false, cloudSyncEnabled: true) == false)
        #expect(effectiveLiveActivityEnabled(isLiveActivityEnabled: false, cloudSyncEnabled: false) == false)
    }

    // MARK: - The resolver, which reads the rule

    @Test("nothing starts while sync is off, even when a scenario would otherwise qualify")
    func nothingStartsWhileSyncIsOff() async {
        await NotificationSettingsFixtures.withStore { store in
            store.isLiveActivityEnabled = true
            let resolver = LiveActivityScenarioResolver()

            let whileOn = resolver.resolve(
                courses: [],
                assignments: [Self.urgentAssignment()],
                preferences: store,
                cloudSyncEnabled: true,
                accentHex: 0,
                now: Self.now
            )
            #expect(whileOn != nil)

            let whileOff = resolver.resolve(
                courses: [],
                assignments: [Self.urgentAssignment()],
                preferences: store,
                cloudSyncEnabled: false,
                accentHex: 0,
                now: Self.now
            )
            #expect(whileOff == nil)
        }
    }

    @Test("the user's own Live Activity preference survives a sync off/on cycle")
    func preferenceSurvivesSyncOffOnCycle() async {
        await NotificationSettingsFixtures.withStore { store in
            store.isLiveActivityEnabled = true
            let resolver = LiveActivityScenarioResolver()

            _ = resolver.resolve(
                courses: [],
                assignments: [Self.urgentAssignment()],
                preferences: store,
                cloudSyncEnabled: false,
                accentHex: 0,
                now: Self.now
            )
            // Suppressed, not erased: the stored preference must not have
            // been touched while sync was off.
            #expect(store.isLiveActivityEnabled == true)

            let resumed = resolver.resolve(
                courses: [],
                assignments: [Self.urgentAssignment()],
                preferences: store,
                cloudSyncEnabled: true,
                accentHex: 0,
                now: Self.now
            )
            #expect(resumed != nil)
            #expect(store.isLiveActivityEnabled == true)
        }
    }
}
