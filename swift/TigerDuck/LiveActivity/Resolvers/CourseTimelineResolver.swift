import Foundation

struct CourseTimelineResolver {
    let dayRadius: Int

    init(dayRadius: Int = 1) {
        self.dayRadius = dayRadius
    }

    func timeline(for courses: [SDCourse], around date: Date) -> [CourseTimeSlot] {
        CourseTimeSlot.buildMultiDaySlots(from: courses, centerDate: date, dayRadius: dayRadius)
    }

    func state(at time: Date, in timeline: [CourseTimeSlot]) -> CourseState {
        let active = timeline.filter { time >= $0.start && time < $0.end }
        if !active.isEmpty {
            return .inClass(active)
        }
        let previous = timeline.last { $0.end <= time }
        let next = timeline.first { $0.start > time }

        if previous == nil, let next {
            return .beforeFirst(next: next)
        }
        if let previous, next == nil {
            return .afterLast(previous: previous)
        }
        return .between(previous: previous, next: next)
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
