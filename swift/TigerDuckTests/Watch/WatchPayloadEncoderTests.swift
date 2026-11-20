import XCTest
import SwiftData
import TigerDuckCore
@testable import TigerDuck

@MainActor
final class WatchPayloadEncoderTests: XCTestCase {

    private func makeCourse(
        no: String = "1142EC1013701",
        name: String = "資料結構",
        instructor: String = "張教授",
        classroom: String = "TR-313",
        schedule: [Int: [String]] = [1: ["3", "4"]],
        classroomMap: [String: String] = [:]
    ) -> SDCourse {
        SDCourse(
            courseNo: no,
            courseName: name,
            instructor: instructor,
            classroom: classroom,
            schedule: schedule,
            classroomMap: classroomMap
        )
    }

    func test_flattensMultiWeekday() {
        let c = makeCourse(schedule: [1: ["3", "4"], 4: ["6", "7"]])
        let snap = WatchPayloadEncoder.encode(
            courses: [c],
            customNames: [:],
            accentHex: "#FF8800",
            syncedAt: Date(timeIntervalSince1970: 1_747_000_000),
            loggedIn: true,
            languageTag: "zh-Hant-TW",
            visualPreset: .default
        )
        XCTAssertEqual(snap.courses.count, 2)
        XCTAssertTrue(snap.courses.contains { $0.weekday == 1 && $0.periodLabel == "3-4" })
        XCTAssertTrue(snap.courses.contains { $0.weekday == 4 && $0.periodLabel == "6-7" })
    }

    func test_perWeekdayClassroomOverridesDefault() {
        let c = makeCourse(
            classroom: "TR-313",
            schedule: [1: ["3", "4"]],
            classroomMap: ["1-3": "TR-409", "1-4": "TR-409"]
        )
        let snap = WatchPayloadEncoder.encode(
            courses: [c], customNames: [:], accentHex: "#000000",
            syncedAt: Date(), loggedIn: true, languageTag: nil, visualPreset: .default
        )
        XCTAssertEqual(snap.courses.first?.classroom, "TR-409")
    }

    func test_idIsStableAndDeterministic() {
        let c = makeCourse(no: "X1", schedule: [1: ["3", "4"]])
        let a = WatchPayloadEncoder.encode(
            courses: [c], customNames: [:], accentHex: "#000",
            syncedAt: Date(), loggedIn: true, languageTag: nil, visualPreset: .default
        )
        let b = WatchPayloadEncoder.encode(
            courses: [c], customNames: [:], accentHex: "#000",
            syncedAt: Date(), loggedIn: true, languageTag: nil, visualPreset: .default
        )
        XCTAssertEqual(a.courses.first?.id, b.courses.first?.id)
        XCTAssertEqual(a.courses.first?.id, "X1-1-3")
    }

    func test_resolvesPeriodBellTimes() {
        let c = makeCourse(schedule: [1: ["3", "4"]])
        let snap = WatchPayloadEncoder.encode(
            courses: [c], customNames: [:], accentHex: "#000",
            syncedAt: Date(), loggedIn: true, languageTag: nil, visualPreset: .default
        )
        XCTAssertEqual(snap.courses.first?.startHHmm, "10:20")
        XCTAssertEqual(snap.courses.first?.endHHmm, "12:10")
    }

    func test_perCourseColorMatchesThemePalette() {
        let c = makeCourse(no: "X1")
        let snap = WatchPayloadEncoder.encode(
            courses: [c], customNames: [:], accentHex: "#FF8800",
            syncedAt: Date(), loggedIn: true, languageTag: nil, visualPreset: .default
        )
        XCTAssertEqual(
            snap.courses.first?.colorHex,
            TigerDuckTheme.courseColorHex(for: "X1")
        )
    }

    func test_customNameAliasOverridesCanonicalName() {
        let c = makeCourse(no: "X1", name: "Canonical 101")
        let snap = WatchPayloadEncoder.encode(
            courses: [c],
            customNames: ["X1": "我的別名"],
            accentHex: "#000",
            syncedAt: Date(),
            loggedIn: true,
            languageTag: nil,
            visualPreset: .default
        )
        XCTAssertEqual(snap.courses.first?.name, "我的別名")
    }

    func test_loggedOut_dropsCachedCourses() {
        let c = makeCourse()
        let snap = WatchPayloadEncoder.encode(
            courses: [c], customNames: [:], accentHex: "#000",
            syncedAt: Date(), loggedIn: false, languageTag: nil, visualPreset: .default
        )
        XCTAssertFalse(snap.loggedIn)
        XCTAssertTrue(snap.courses.isEmpty)
    }

    func test_quietDaysAndSkippedDates_reachThePayload() {
        let c = makeCourse()
        c.skippedDates = ["2026-10-09"]
        let snap = WatchPayloadEncoder.encode(
            courses: [c], customNames: [:], accentHex: "#000", syncedAt: Date(),
            loggedIn: true, languageTag: nil, visualPreset: .default, quietDays: ["2026-10-10"]
        )
        XCTAssertEqual(snap.quietDays, ["2026-10-10"])
        XCTAssertEqual(snap.courses.first?.skippedDates, ["2026-10-09"])
    }

    func test_watchDayKeyMatchesTheWidgetKey() {
        let days = [
            Date(timeIntervalSince1970: 1_790_000_000),
            Date(timeIntervalSince1970: 1_767_196_800),
            Date(timeIntervalSince1970: 1_767_196_799),
        ]
        for day in days {
            XCTAssertEqual(TaipeiTime.dayKey(for: day), WidgetTimelineDerivation.dateKey(for: day))
        }
    }

    func test_carriesEachChangedDaysClassesOnTheirMeeting() throws {
        let c = makeCourse(no: "CC900", schedule: [4: ["2", "3", "7"]])
        let feed = try JSONSerialization.data(withJSONObject: ["term": "1151", "changes": [
            ["id": 1, "course_no": "CC900", "kind": "cancelled", "periods": ["7"], "class_days": ["2026-11-05"]],
            ["id": 2, "course_no": "CC900", "kind": "room", "room": "TR-411", "class_days": ["2026-11-12"]],
            ["id": 3, "course_no": "CC900", "kind": "cancelled", "periods": ["2"], "class_days": ["2026-11-19"]],
            ["id": 4, "course_no": "CC900", "kind": "room", "room": "TR-411", "periods": ["3"], "class_days": ["2026-11-26"]],
        ]] as [String: Any])
        let snap = WatchPayloadEncoder.encode(
            courses: [c], customNames: [:], accentHex: "#000", syncedAt: Date(), loggedIn: true,
            languageTag: nil, visualPreset: .default, changes: try CourseChanges(json: feed)
        )

        let byLabel = Dictionary(uniqueKeysWithValues: snap.courses.map { ($0.periodLabel, $0) })
        func held(_ label: String, on day: String) -> [WatchCourse] {
            let parts = day.split(separator: "-").compactMap { Int($0) }
            let noon = TaipeiTime.calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))!
            return byLabel[label].map { NextClassResolver.todaysClasses(courses: [$0], now: noon, quietDays: []) } ?? []
        }
        func shown(_ label: String, on day: String) -> [String] {
            held(label, on: day).map { "\($0.periodLabel) \($0.startHHmm)-\($0.endHHmm) \($0.classroom)" }
        }
        XCTAssertEqual(shown("2-3", on: "2026-11-05"), ["2-3 09:10-11:10 TR-313"])
        XCTAssertEqual(shown("7", on: "2026-11-05"), [])
        XCTAssertEqual(shown("2-3", on: "2026-11-12"), ["2-3 09:10-11:10 TR-411"])
        XCTAssertEqual(held("2-3", on: "2026-11-12").first?.dayChange, WatchCourseChange(cancelled: false, room: "TR-411"))
        XCTAssertEqual(shown("2-3", on: "2026-11-19"), ["3 10:20-11:10 TR-313"])
        XCTAssertEqual(shown("2-3", on: "2026-11-26"), ["2 09:10-10:00 TR-313", "3 10:20-11:10 TR-411"])
        XCTAssertEqual(held("2-3", on: "2026-11-26").map(\.dayChange?.room), [nil, "TR-411"])
    }
}
