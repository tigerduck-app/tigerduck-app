import Testing
import Foundation
@testable import TigerDuck

struct TimeSliderViewModelTests {

    @Test func dateFromTimeString_parsesCorrectly() {
        let ref = Calendar.current.startOfDay(for: Date())
        let date = CourseTimeSlot.dateFromTimeString("10:20", on: ref)!
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        #expect(comps.hour == 10)
        #expect(comps.minute == 20)
    }

    @Test func dateFromTimeString_invalidReturnsNil() {
        let ref = Date()
        #expect(CourseTimeSlot.dateFromTimeString("invalid", on: ref) == nil)
        #expect(CourseTimeSlot.dateFromTimeString("", on: ref) == nil)
    }

    @Test func xOffset_returnsCorrectPixels() {
        let vm = TimeSliderViewModel(weekday: 1)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let now = calendar.date(byAdding: .hour, value: 10, to: today)!
        vm.selectedTime = now

        // 60 minutes in the future → 60 * 1.5 = 90 pixels right
        let future = calendar.date(byAdding: .hour, value: 11, to: today)!
        let offset = vm.xOffset(for: future)
        #expect(abs(offset - 90) < 0.01)

        // 30 minutes in the past → -30 * 1.5 = -45 pixels left
        let past = calendar.date(byAdding: .minute, value: -30, to: now)!
        let pastOffset = vm.xOffset(for: past)
        #expect(abs(pastOffset - (-45)) < 0.01)
    }

    @Test func courseState_inClass() {
        let vm = TimeSliderViewModel(weekday: 1)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let slot = makeMockSlot(
            courseNo: "MATH101",
            start: calendar.date(byAdding: .hour, value: 10, to: today)!,
            end: calendar.date(byAdding: .hour, value: 12, to: today)!
        )
        vm.timeSlots = [slot]

        let during = calendar.date(byAdding: .hour, value: 11, to: today)!
        let state = vm.courseState(at: during)
        if case .inClass(let c) = state {
            #expect(c.courseNo == "MATH101")
        } else {
            Issue.record("Expected .inClass, got \(state)")
        }
    }

    @Test func courseState_beforeFirst() {
        let vm = TimeSliderViewModel(weekday: 1)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let slot = makeMockSlot(
            courseNo: "MATH101",
            start: calendar.date(byAdding: .hour, value: 10, to: today)!,
            end: calendar.date(byAdding: .hour, value: 12, to: today)!
        )
        vm.timeSlots = [slot]

        let before = calendar.date(byAdding: .hour, value: 9, to: today)!
        let state = vm.courseState(at: before)
        if case .beforeFirst(let next) = state {
            #expect(next.courseNo == "MATH101")
        } else {
            Issue.record("Expected .beforeFirst, got \(state)")
        }
    }

    @Test func courseState_between() {
        let vm = TimeSliderViewModel(weekday: 1)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let slot1 = makeMockSlot(
            courseNo: "MATH101",
            start: calendar.date(byAdding: .hour, value: 8, to: today)!,
            end: calendar.date(byAdding: .hour, value: 10, to: today)!
        )
        let slot2 = makeMockSlot(
            courseNo: "PHYS201",
            start: calendar.date(byAdding: .hour, value: 13, to: today)!,
            end: calendar.date(byAdding: .hour, value: 15, to: today)!
        )
        vm.timeSlots = [slot1, slot2]

        let gap = calendar.date(byAdding: .hour, value: 11, to: today)!
        let state = vm.courseState(at: gap)
        if case .between(let prev, let next) = state {
            #expect(prev?.courseNo == "MATH101")
            #expect(next?.courseNo == "PHYS201")
        } else {
            Issue.record("Expected .between, got \(state)")
        }
    }

    private func makeMockSlot(courseNo: String, start: Date, end: Date) -> CourseTimeSlot {
        let course = SDCourse(
            courseNo: courseNo,
            courseName: courseNo,
            instructor: "Test",
            credits: 3,
            classroom: "101",
            enrolledCount: 30,
            maxCount: 50,
            schedule: [:]
        )
        return CourseTimeSlot(id: courseNo, course: course, start: start, end: end)
    }
}
