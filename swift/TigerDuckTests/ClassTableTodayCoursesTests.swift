import Foundation
import Testing
@testable import TigerDuck

/// The class table's "today" carousel follows the school calendar: nothing on
/// a day classes do not meet.
@MainActor
struct ClassTableTodayCoursesTests {
    private static let everyDay = SDCourse(
        courseNo: "TEST100",
        courseName: "Test",
        schedule: Dictionary(uniqueKeysWithValues: (1...7).map { ($0, ["3", "4"]) })
    )

    @Test func holiday_hidesTodaysCourses() {
        let holiday = ClassTableViewModel(isQuietDay: { _ in true })
        holiday.currentSemesterCourses = [Self.everyDay]

        #expect(holiday.todayCourses.isEmpty)
    }

    @Test func schoolDay_showsTodaysCourses() {
        let schoolDay = ClassTableViewModel(isQuietDay: { _ in false })
        schoolDay.currentSemesterCourses = [Self.everyDay]

        // Out of term the carousel is empty for its own reason, which this
        // test does not pin; in term the course has to be there.
        if AcademicCalendarStore.shared.calendar.isInSession() {
            #expect(schoolDay.todayCourses.map(\.courseNo) == ["TEST100"])
        }
    }
}
