import Foundation
import Observation
import Testing
@testable import TigerDuck

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

    /// Set from `withObservationTracking`'s `onChange`, which is `@Sendable`.
    private final class Flag: @unchecked Sendable {
        var raised = false
    }

    @Test func holidayToggle_redrawsTodaysCourses() {
        let viewModel = ClassTableViewModel(isClassDay: { _ in true })
        let redrawn = Flag()
        withObservationTracking {
            _ = viewModel.todayCourses
        } onChange: {
            redrawn.raised = true
        }

        NotificationCenter.default.post(name: AppConstants.holidayNotifyDidChange, object: nil)

        #expect(redrawn.raised)
    }

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
        #expect(Self.calendar.isClassDay(Self.day(2026, 9, 25), optedIn: [1]))
        #expect(!Self.calendar.isClassDay(Self.day(2026, 8, 3), optedIn: []))
    }
}
