// Live Activity is unavailable while course sync is off, as the footnote
// `sync_courses_footer_platform_note` promises; `effectiveLiveActivityEnabled` decides it.
// `ScheduleSyncServiceTests` and `LiveActivityCoordinatorTests` pin its other readers.
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
}
