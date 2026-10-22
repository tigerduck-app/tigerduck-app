import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct LiveActivitySyncGateTests {

    private static let now = Date(timeIntervalSince1970: 1_757_500_000)

    private static func urgentAssignment() -> SDAssignment {
        SDAssignment(
            assignmentId: "a1",
            courseNo: "CS101",
            courseName: "Test Course",
            title: "Homework",
            dueDate: now.addingTimeInterval(3600)
        )
    }

    @Test("the effective rule is both switches ANDed — all four combinations")
    func allFourCombinations() {
        #expect(effectiveLiveActivityEnabled(isLiveActivityEnabled: true, cloudSyncEnabled: true) == true)
        #expect(effectiveLiveActivityEnabled(isLiveActivityEnabled: true, cloudSyncEnabled: false) == false)
        #expect(effectiveLiveActivityEnabled(isLiveActivityEnabled: false, cloudSyncEnabled: true) == false)
        #expect(effectiveLiveActivityEnabled(isLiveActivityEnabled: false, cloudSyncEnabled: false) == false)
    }

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
