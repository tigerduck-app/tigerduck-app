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

    @Test func normalizedPosition_clampsToRange() {
        let vm = TimeSliderViewModel(weekday: 1)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .hour, value: 8, to: today)!
        let end = calendar.date(byAdding: .hour, value: 18, to: today)!
        vm.rangeStart = start
        vm.rangeEnd = end

        let before = calendar.date(byAdding: .hour, value: 7, to: today)!
        #expect(vm.normalizedPosition(for: before) == 0.0)

        let after = calendar.date(byAdding: .hour, value: 19, to: today)!
        #expect(vm.normalizedPosition(for: after) == 1.0)

        let mid = calendar.date(byAdding: .hour, value: 13, to: today)!
        let pos = vm.normalizedPosition(for: mid)
        #expect(pos > 0.49 && pos < 0.51)
    }

    @Test func timeForNormalized_roundtrips() {
        let vm = TimeSliderViewModel(weekday: 1)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        vm.rangeStart = calendar.date(byAdding: .hour, value: 8, to: today)!
        vm.rangeEnd = calendar.date(byAdding: .hour, value: 18, to: today)!

        let time = vm.time(forNormalized: 0.5)
        let pos = vm.normalizedPosition(for: time)
        #expect(abs(pos - 0.5) < 0.001)
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
        vm.rangeStart = slot.start.addingTimeInterval(-30 * 60)
        vm.rangeEnd = slot.end.addingTimeInterval(30 * 60)

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
        vm.rangeStart = slot.start.addingTimeInterval(-30 * 60)
        vm.rangeEnd = slot.end.addingTimeInterval(30 * 60)

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
        vm.rangeStart = slot1.start.addingTimeInterval(-30 * 60)
        vm.rangeEnd = slot2.end.addingTimeInterval(30 * 60)

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
