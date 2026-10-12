import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct CourseTimeSlotTests {
    private static let tuesday = AppConstants.taipeiCalendar.date(
        from: DateComponents(year: 2026, month: 9, day: 22, hour: 9)
    )!

    private static func course(_ courseNo: String, periods: [String]) -> SDCourse {
        SDCourse(courseNo: courseNo, courseName: courseNo, schedule: [2: periods])
    }

    @Test func meetingSlotsHoldTheDaysBlocks() {
        let slots = CourseTimeSlot.meetingSlots(
            from: [Self.course("CS101", periods: ["3", "4", "7"])],
            on: Self.tuesday,
            isClassDay: { _ in true }
        )
        #expect(slots.map(\.id) == ["CS101_20260922_3", "CS101_20260922_7"])
        #expect(slots.map(\.periods) == [["3", "4"], ["7"]])
    }

    /// The Mac Home cards list today's classes and the next one from these, so a holiday the
    /// user has not opted back into shows no class, as on iOS.
    @Test func meetingSlotsAreEmptyOnADayClassesDoNotMeet() {
        let slots = CourseTimeSlot.meetingSlots(
            from: [Self.course("CS101", periods: ["3", "4"])],
            on: Self.tuesday,
            isClassDay: { _ in false }
        )
        #expect(slots.isEmpty)
    }

    @Test func meetingSlotsLeaveOutACourseSkippedThatDay() {
        let skipped = Self.course("CS101", periods: ["3"])
        skipped.skippedDates = ["2026-09-22"]
        let slots = CourseTimeSlot.meetingSlots(
            from: [skipped, Self.course("CS102", periods: ["6"])],
            on: Self.tuesday,
            isClassDay: { _ in true }
        )
        #expect(slots.map(\.course.courseNo) == ["CS102"])
    }
}
