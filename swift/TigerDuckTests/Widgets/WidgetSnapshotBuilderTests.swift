import Foundation
import Testing
@testable import TigerDuck

struct WidgetSnapshotBuilderTests {
    @Test func builds_emptyState_whenNotLoggedIn() {
        let input = WidgetSnapshotBuilder.Input(
            courses: [],
            customNames: [:],
            customColors: [:],
            isLoggedIn: false,
            accentColorHex: 0x007AFF,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let snapshot = WidgetSnapshotBuilder.build(input)
        #expect(snapshot.isLoggedIn == false)
        #expect(snapshot.courses.isEmpty)
        #expect(snapshot.version == WidgetSnapshot.currentVersion)
    }

    @Test func resolvesDisplayName_customNameWins() {
        let course = SDCourse(courseNo: "EC1013701", courseName: "資料結構與演算法",
                              classroom: "TR-313", schedule: [1: ["B"]])
        let input = WidgetSnapshotBuilder.Input(
            courses: [course],
            customNames: ["EC1013701": "DS"],
            customColors: [:],
            isLoggedIn: true,
            accentColorHex: 0x007AFF,
            now: Date()
        )
        let snapshot = WidgetSnapshotBuilder.build(input)
        #expect(snapshot.courses.first?.displayName == "DS")
    }

    @Test func resolvesDisplayName_fallsBackToCourseName() {
        let course = SDCourse(courseNo: "EC1013701", courseName: "Data Structures",
                              classroom: "TR-313", schedule: [1: ["B"]])
        let input = WidgetSnapshotBuilder.Input(
            courses: [course], customNames: [:], customColors: [:], isLoggedIn: true,
            accentColorHex: 0x007AFF, now: Date()
        )
        let snapshot = WidgetSnapshotBuilder.build(input)
        #expect(snapshot.courses.first?.displayName == "Data Structures")
    }

    @Test func activeWeekdays_includesWeekendOnlyIfScheduled() {
        let weekdayOnly = SDCourse(courseNo: "A", courseName: "A", classroom: "",
                                   schedule: [1: ["2"], 3: ["3"]])
        let withSaturday = SDCourse(courseNo: "B", courseName: "B", classroom: "",
                                    schedule: [6: ["2"]])
        let input = WidgetSnapshotBuilder.Input(
            courses: [weekdayOnly, withSaturday],
            customNames: [:], customColors: [:], isLoggedIn: true, accentColorHex: 0, now: Date()
        )
        let snapshot = WidgetSnapshotBuilder.build(input)
        #expect(snapshot.activeWeekdays == [1, 2, 3, 4, 5, 6])
    }

    @Test func activePeriodIds_inChronologicalOrder() {
        let course = SDCourse(courseNo: "A", courseName: "A", classroom: "",
                              schedule: [1: ["A", "5"], 2: ["10"]])
        let input = WidgetSnapshotBuilder.Input(
            courses: [course], customNames: [:], customColors: [:], isLoggedIn: true,
            accentColorHex: 0, now: Date()
        )
        let snapshot = WidgetSnapshotBuilder.build(input)
        // Expect periods to appear in chronological order per AppConstants.Periods.chronologicalOrder
        let positions = ["5", "10", "A"].map { snapshot.activePeriodIds.firstIndex(of: $0)! }
        #expect(positions == positions.sorted())
    }

    @Test func periodTimes_mappedFromAppConstants() {
        let input = WidgetSnapshotBuilder.Input(
            courses: [], customNames: [:], customColors: [:], isLoggedIn: true, accentColorHex: 0, now: Date()
        )
        let snapshot = WidgetSnapshotBuilder.build(input)
        // Verify the *mapping* is faithful, not the values themselves —
        // those live in AppConstants and may change without affecting
        // the builder's correctness.
        for (periodId, expected) in AppConstants.PeriodTimes.mapping {
            #expect(snapshot.periodTimes[periodId]?.start == expected.start, "period \(periodId) start mismatch")
            #expect(snapshot.periodTimes[periodId]?.end == expected.end, "period \(periodId) end mismatch")
        }
        #expect(snapshot.periodTimes.count == AppConstants.PeriodTimes.mapping.count)
    }
}
