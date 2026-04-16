import Foundation

/// Pure course-state resolver extracted from `TimeSliderViewModel` so it
/// can be reused by the Live Activity scenario resolver and any future
/// background component, without dragging the slider's drag/haptic state
/// along with it.
///
/// A smaller default `dayRadius` is used here because Live Activity only
/// needs to answer "is a class happening now?" and "what is next?", not
/// to power a scrollable multi-week timeline.
struct CourseTimelineResolver {
    /// Number of days scanned on each side of the resolution date. Defaults
    /// to 1 (yesterday / today / tomorrow) to cover midnight edge cases.
    let dayRadius: Int

    init(dayRadius: Int = 1) {
        self.dayRadius = dayRadius
    }

    /// Build the timeline of course slots around `date`.
    func timeline(for courses: [SDCourse], around date: Date) -> [CourseTimeSlot] {
        CourseTimeSlot.buildMultiDaySlots(from: courses, centerDate: date, dayRadius: dayRadius)
    }

    /// Resolve state at `time` using a pre-built timeline.
    func state(at time: Date, in timeline: [CourseTimeSlot]) -> CourseState {
        for slot in timeline where time >= slot.start && time <= slot.end {
            return .inClass(slot)
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

    /// Convenience: build + resolve in one call.
    func state(at time: Date, courses: [SDCourse]) -> CourseState {
        state(at: time, in: timeline(for: courses, around: time))
    }

    /// Like `state(at:in:)` but drops slots whose course is skipped for
    /// that slot's date. Live Activity rules should use this variant so
    /// "翹課" classes do not trigger `inClass` or `classPreparing`.
    func nonSkippedState(at time: Date, in timeline: [CourseTimeSlot]) -> CourseState {
        let filtered = timeline.filter { !$0.course.isSkipped(on: $0.date) }
        return state(at: time, in: filtered)
    }

    /// Convenience variant that builds the timeline then applies the skip filter.
    func nonSkippedState(at time: Date, courses: [SDCourse]) -> CourseState {
        nonSkippedState(at: time, in: timeline(for: courses, around: time))
    }
}
