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

    @Test func xOffset_returnsZeroWithNoCourses() {
        let vm = TimeSliderViewModel()
        vm.configure(courses: [])

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let now = calendar.date(byAdding: .hour, value: 10, to: today)!
        vm.selectedTime = now

        // With no courses, anchors are empty so all offsets should be 0
        let future = calendar.date(byAdding: .hour, value: 11, to: today)!
        #expect(vm.xOffset(for: future) == 0)

        let past = calendar.date(byAdding: .minute, value: -30, to: now)!
        #expect(vm.xOffset(for: past) == 0)
    }

    @Test func xOffset_returnsCorrectPixels() {
        let vm = TimeSliderViewModel()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // Course with periods "3","4" (10:20–12:10) every weekday so anchors are built
        let allDays = Dictionary(uniqueKeysWithValues: (1...7).map { ($0, ["3", "4"]) })
        let course = SDCourse(courseNo: "TEST100", courseName: "Test", schedule: allDays)
        vm.configure(courses: [course])

        // Pick 11:00 as selectedTime — within the 10:20–12:10 block
        let selectedTime = calendar.date(byAdding: DateComponents(hour: 11), to: today)!
        vm.selectedTime = selectedTime

        // Within a single course block, mapping is linear (deltaMinutes × ppm)
        let ppm = TimeSliderMetrics.pointsPerMinute

        // +15 min → 11:15, still inside block
        let future = calendar.date(byAdding: .minute, value: 15, to: selectedTime)!
        let offset = vm.xOffset(for: future)
        #expect(abs(offset - 15.0 * ppm) < 0.01)

        // −15 min → 10:45, still inside block
        let past = calendar.date(byAdding: .minute, value: -15, to: selectedTime)!
        let pastOffset = vm.xOffset(for: past)
        #expect(abs(pastOffset - (-15.0 * ppm)) < 0.01)
    }

    @Test func courseState_inClass() {
        let vm = TimeSliderViewModel()
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
            #expect(c.course.courseNo == "MATH101")
        } else {
            Issue.record("Expected .inClass, got \(state)")
        }
    }

    @Test func courseState_beforeFirst() {
        let vm = TimeSliderViewModel()
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
            #expect(next.course.courseNo == "MATH101")
        } else {
            Issue.record("Expected .beforeFirst, got \(state)")
        }
    }

    @Test func courseState_between() {
        let vm = TimeSliderViewModel()
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
            #expect(prev?.course.courseNo == "MATH101")
            #expect(next?.course.courseNo == "PHYS201")
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
        return CourseTimeSlot(id: courseNo, course: course, start: start, end: end, date: start)
    }
}
