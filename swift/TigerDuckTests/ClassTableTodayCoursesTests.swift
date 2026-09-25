import Foundation
import Testing
@testable import TigerDuck

/// The class table's "today" carousel shows courses only on a class day: in
/// term, and not a holiday the user has left quiet.
@MainActor
struct ClassTableTodayCoursesTests {
    private static let everyDay = SDCourse(
        courseNo: "TEST100",
        courseName: "Test",
        schedule: Dictionary(uniqueKeysWithValues: (1...7).map { ($0, ["3", "4"]) })
    )

    @Test func classDay_showsTodaysCourses() {
        let viewModel = ClassTableViewModel(isClassDay: { _ in true })
        viewModel.currentSemesterCourses = [Self.everyDay]

        #expect(viewModel.todayCourses.map(\.courseNo) == ["TEST100"])
    }

    @Test func dayWithoutClasses_showsNothing() {
        let viewModel = ClassTableViewModel(isClassDay: { _ in false })
        viewModel.currentSemesterCourses = [Self.everyDay]

        #expect(viewModel.todayCourses.isEmpty)
    }

    // MARK: - What counts as a class day

    private static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        AcademicCalendar.calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private static let calendar = AcademicCalendar(
        revision: 1,
        terms: [SemesterTerm(code: "1151", start: day(2026, 9, 14), end: day(2027, 1, 8))],
        holidays: [
            Holiday(
                id: 1,
                nameZh: "中秋節",
                nameEn: "Mid-Autumn Festival",
                start: day(2026, 9, 25),
                end: day(2026, 9, 25)
            )
        ]
    )

    @Test func classDay_isInTermAndNotAQuietHoliday() {
        #expect(Self.calendar.isClassDay(Self.day(2026, 9, 24), optedIn: []))
        #expect(!Self.calendar.isClassDay(Self.day(2026, 9, 25), optedIn: []))
        // "Still have class?" on that holiday.
        #expect(Self.calendar.isClassDay(Self.day(2026, 9, 25), optedIn: [1]))
        // Before the term begins.
        #expect(!Self.calendar.isClassDay(Self.day(2026, 8, 3), optedIn: []))
    }
}
