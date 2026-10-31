import Foundation
import Testing
import TigerDuckCore
@testable import TigerDuck

@MainActor
struct AssignmentRoundCoursesTests {
    private static func course(_ id: Int, _ idnumber: String, startedIn year: Int, _ month: Int) -> MoodleEnrolledCourse {
        MoodleEnrolledCourse(
            id: id, fullname: "\(idnumber) Course", shortname: "", idnumber: idnumber,
            startDate: TaipeiTime.calendar.date(from: DateComponents(year: year, month: month, day: 1)),
            endDate: nil
        )
    }

    @Test("a retaken course keeps only this term's Moodle course")
    func retakenCourseKeepsThisTerm() {
        let failed = Self.course(10, "1132CS1001301", startedIn: 2025, 2)
        let retaken = Self.course(20, "1151CS1001301", startedIn: 2026, 9)
        let other = Self.course(30, "1151EE2005301", startedIn: 2026, 9)
        let kept = AppServiceBridge.coursesForTerm([failed, other, retaken], semester: "1151")
        #expect(kept.map(\.id) == [30, 20])
    }

    @Test("without this term's course, the one that started last is kept")
    func latestStartWinsWithoutThisTerm() {
        let older = Self.course(10, "1131CS1001301", startedIn: 2024, 9)
        let newer = Self.course(20, "1141CS1001301", startedIn: 2025, 9)
        #expect(AppServiceBridge.coursesForTerm([newer, older], semester: "1142").map(\.id) == [20])
    }

    @Test("a course number with one Moodle course keeps it, whatever its term")
    func singleCourseIsKept() {
        let yearLong = Self.course(10, "1141PE1001301", startedIn: 2025, 9)
        #expect(AppServiceBridge.coursesForTerm([yearLong], semester: "1142").map(\.id) == [10])
    }
}
