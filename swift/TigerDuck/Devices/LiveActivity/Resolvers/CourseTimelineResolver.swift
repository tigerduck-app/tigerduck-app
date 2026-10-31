import Foundation
import TigerDuckCore

struct CourseTimelineResolver {
    let dayRadius: Int

    init(dayRadius: Int = 1) {
        self.dayRadius = dayRadius
    }

    func timeline(for courses: [SDCourse], around date: Date) -> [CourseTimeSlot] {
        CourseTimeSlot.buildMultiDaySlots(from: courses, centerDate: date, dayRadius: dayRadius)
    }

    func state(at time: Date, in timeline: [CourseTimeSlot]) -> CourseState {
        ClassTimeline.state(at: time, in: timeline)
    }

    func state(at time: Date, courses: [SDCourse]) -> CourseState {
        state(at: time, in: timeline(for: courses, around: time))
    }

    func nonSkippedState(at time: Date, in timeline: [CourseTimeSlot]) -> CourseState {
        let filtered = timeline.filter { !$0.isSkippedOrCancelled }
        return state(at: time, in: filtered)
    }

    func nonSkippedState(at time: Date, courses: [SDCourse]) -> CourseState {
        nonSkippedState(at: time, in: timeline(for: courses, around: time))
    }
}
