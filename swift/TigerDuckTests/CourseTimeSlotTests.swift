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

    @Test func aSlotIdTellsWhetherItsClassIsSkipped() {
        let skipped = Self.course("CS101", periods: ["3"])
        skipped.skippedDates = ["2026-09-22"]
        let userAdded = Self.course("custom_A1", periods: ["6"])
        userAdded.skippedDates = ["2026-09-22"]
        let courses = [skipped, userAdded, Self.course("CS102", periods: ["6"])]

        #expect(CourseTimeSlot.isSkipped(slotId: "CS101_20260922_3", in: courses))
        #expect(CourseTimeSlot.isSkipped(slotId: "custom_A1_20260922_6", in: courses))
        #expect(!CourseTimeSlot.isSkipped(slotId: "CS101_20260929_3", in: courses))
        #expect(!CourseTimeSlot.isSkipped(slotId: "CS102_20260922_6", in: courses))
        #expect(!CourseTimeSlot.isSkipped(slotId: "CS103_20260922_3", in: courses))
        #expect(!CourseTimeSlot.isSkipped(slotId: "901", in: courses))
        #expect(!CourseTimeSlot.isSkipped(slotId: "CS101_2026-09-22_3", in: courses))
    }

    @Test func aSlotIdIsTheOneBuildSlotsWrites() throws {
        let course = Self.course("CS101", periods: ["3"])
        let slot = try #require(CourseTimeSlot.buildSlots(from: [course], weekday: 2, on: Self.tuesday).first)
        course.skippedDates = ["2026-09-22"]

        #expect(CourseTimeSlot.isSkipped(slotId: slot.id, in: [course]))
    }
}
