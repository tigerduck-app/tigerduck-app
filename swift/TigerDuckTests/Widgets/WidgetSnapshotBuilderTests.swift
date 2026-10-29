import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct WidgetSnapshotBuilderTests {
    @Test func builds_emptyState_whenNotLoggedIn() {
        let input = WidgetSnapshotBuilder.Input(
            courses: [],
            customNames: [:],
            colorMap: [:],
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
            colorMap: [:],
            isLoggedIn: true,
            accentColorHex: 0x007AFF,
            now: Date()
        )
        let snapshot = WidgetSnapshotBuilder.build(input)
        #expect(snapshot.courses.first?.displayName == "DS")
    }

    @Test func carriesThePerSlotRoomMap() {
        let course = SDCourse(
            courseNo: "EC1013701", courseName: "Data Structures", classroom: "TR-313, IB-101",
            schedule: [1: ["3"], 4: ["7"]], classroomMap: ["1-3": "TR-313", "4-7": "IB-101"]
        )
        let input = WidgetSnapshotBuilder.Input(
            courses: [course], customNames: [:], colorMap: [:], isLoggedIn: true,
            accentColorHex: 0x007AFF, now: Date()
        )
        let snapshot = WidgetSnapshotBuilder.build(input)
        #expect(snapshot.courses.first?.classroomMap == ["1-3": "TR-313", "4-7": "IB-101"])
    }

    @Test func resolvesDisplayName_fallsBackToCourseName() {
        let course = SDCourse(courseNo: "EC1013701", courseName: "Data Structures",
                              classroom: "TR-313", schedule: [1: ["B"]])
        let input = WidgetSnapshotBuilder.Input(
            courses: [course], customNames: [:], colorMap: [:], isLoggedIn: true,
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
            customNames: [:], colorMap: [:], isLoggedIn: true, accentColorHex: 0, now: Date()
        )
        let snapshot = WidgetSnapshotBuilder.build(input)
        #expect(snapshot.activeWeekdays == [1, 2, 3, 4, 5, 6])
    }

    @Test func activePeriodIds_inChronologicalOrder() {
        let course = SDCourse(courseNo: "A", courseName: "A", classroom: "",
                              schedule: [1: ["A", "5"], 2: ["10"]])
        let input = WidgetSnapshotBuilder.Input(
            courses: [course], customNames: [:], colorMap: [:], isLoggedIn: true,
            accentColorHex: 0, now: Date()
        )
        let snapshot = WidgetSnapshotBuilder.build(input)
        let positions = ["5", "10", "A"].map { snapshot.activePeriodIds.firstIndex(of: $0)! }
        #expect(positions == positions.sorted())
    }

    @Test func periodTimes_mappedFromAppConstants() {
        let input = WidgetSnapshotBuilder.Input(
            courses: [], customNames: [:], colorMap: [:], isLoggedIn: true, accentColorHex: 0, now: Date()
        )
        let snapshot = WidgetSnapshotBuilder.build(input)
        for (periodId, expected) in AppConstants.PeriodTimes.mapping {
            #expect(snapshot.periodTimes[periodId]?.start == expected.start, "period \(periodId) start mismatch")
            #expect(snapshot.periodTimes[periodId]?.end == expected.end, "period \(periodId) end mismatch")
        }
        #expect(snapshot.periodTimes.count == AppConstants.PeriodTimes.mapping.count)
    }

    @Test func carriesTheTermsChangedMeetingsButNotTheNotes() throws {
        let course = SDCourse(courseNo: "CC900", courseName: "Compilers", classroom: "T4-501", schedule: [4: ["2", "3", "7"]])
        func row(_ id: Int, _ kind: String, _ day: String, periods: [String]? = nil, _ values: [String: String] = [:]) -> [String: Any] {
            var row: [String: Any] = ["id": id, "course_no": "CC900", "kind": kind, "class_days": [day]]
            if let periods { row["periods"] = periods }
            values.forEach { row[$0.key] = $0.value }
            return row
        }
        let feed = try JSONSerialization.data(withJSONObject: ["term": "1151", "changes": [
            row(1, "cancelled", "2026-11-05", periods: ["7"]),
            row(2, "room", "2026-11-12", periods: ["2", "3"], ["room": "TR-411"]),
            row(3, "start", "2026-11-12", periods: ["2", "3"], ["start": "09:30"]),
            row(4, "note", "2026-11-19", ["note_zh": "期中考"]),
        ]] as [String: Any])
        let input = WidgetSnapshotBuilder.Input(
            courses: [course], customNames: [:], colorMap: [:], isLoggedIn: true,
            accentColorHex: 0x007AFF, now: Date(), changes: try CourseChanges(json: feed)
        )

        let whole = [
            SnapshotCourseChange(day: "2026-11-05", periods: ["7"], cancelled: true, room: nil, start: nil, end: nil),
            SnapshotCourseChange(day: "2026-11-12", periods: ["2", "3"], cancelled: false, room: "TR-411", start: "09:30", end: nil),
        ]
        let built = WidgetSnapshotBuilder.build(input).courses.first
        #expect(built?.changes == whole)
        #expect(built?.meetingChanges == whole)
    }

    @Test func splitsAMeetingChangedInPartIntoItsClassesButKeepsItWholeForTheTable() throws {
        let course = SDCourse(courseNo: "CC900", courseName: "Compilers", classroom: "T4-501", schedule: [4: ["2", "3", "4"]])
        let feed = try JSONSerialization.data(withJSONObject: ["term": "1151", "changes": [
            ["id": 1, "course_no": "CC900", "kind": "cancelled", "periods": ["2"], "class_days": ["2026-11-05"]],
            ["id": 2, "course_no": "CC900", "kind": "room", "periods": ["4"], "room": "TR-411", "class_days": ["2026-11-05"]],
        ]] as [String: Any])
        let input = WidgetSnapshotBuilder.Input(
            courses: [course], customNames: [:], colorMap: [:], isLoggedIn: true,
            accentColorHex: 0x007AFF, now: Date(), changes: try CourseChanges(json: feed)
        )

        let built = WidgetSnapshotBuilder.build(input).courses.first
        #expect(built?.changes == [
            SnapshotCourseChange(day: "2026-11-05", periods: ["2"], cancelled: true, room: nil, start: nil, end: nil),
            SnapshotCourseChange(day: "2026-11-05", periods: ["3"], cancelled: false, room: nil, start: nil, end: nil),
            SnapshotCourseChange(day: "2026-11-05", periods: ["4"], cancelled: false, room: "TR-411", start: nil, end: nil),
        ])
        #expect(built?.meetingChanges == [
            SnapshotCourseChange(day: "2026-11-05", periods: ["2", "3", "4"], cancelled: false, room: "TR-411", start: nil, end: nil),
        ])
    }
}
