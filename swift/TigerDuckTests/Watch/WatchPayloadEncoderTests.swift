import XCTest
import SwiftData
@testable import TigerDuck

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
        // Assumes AppConstants.PeriodTimes.mapping["3"] = (start:"10:20", end:"11:10")
        // and ["4"] = (start:"11:20", end:"12:10"). If those constants change,
        // update this assertion to match.
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
        // Encoder must use the user-visible per-course palette, not the
        // global accent — otherwise the watch swatch drifts from the phone.
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
        // Logout posts a data update before SwiftData rows are deleted, and
        // the watch UI shows non-empty `courses` ahead of the signed-out
        // empty state — so the encoder must strip courses when loggedIn is
        // false to avoid leaking the previous user's schedule.
        let c = makeCourse()
        let snap = WatchPayloadEncoder.encode(
            courses: [c], customNames: [:], accentHex: "#000",
            syncedAt: Date(), loggedIn: false, languageTag: nil, visualPreset: .default
        )
        XCTAssertFalse(snap.loggedIn)
        XCTAssertTrue(snap.courses.isEmpty)
    }
}
