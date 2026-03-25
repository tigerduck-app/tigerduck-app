import SwiftUI

@Observable
final class TimeSliderViewModel {
    // MARK: - Data
    var timeSlots: [CourseTimeSlot] = []

    // MARK: - State
    var selectedTime: Date = Date()
    var isUserDragging: Bool = false

    // MARK: - Scale
    /// Pixels per minute — controls how zoomed the timeline is
    let pixelsPerMinute: CGFloat = 1.5

    // MARK: - Private
    private var autoReturnTask: Task<Void, Never>?
    private let weekday: Int

    var hasCourses: Bool { !timeSlots.isEmpty }

    init(weekday: Int = Date().scheduleWeekday) {
        self.weekday = weekday
    }

    // MARK: - Configuration

    func configure(courses: [SDCourse]) {
        timeSlots = CourseTimeSlot.buildSlots(from: courses, weekday: weekday)
        if !isUserDragging {
            selectedTime = Date()
        }
    }

    // MARK: - Real-time Update

    func tick(_ now: Date) {
        if !isUserDragging {
            selectedTime = now
        }
    }

    // MARK: - Course State Resolution

    func courseState(at time: Date) -> CourseState {
        for slot in timeSlots {
            if time >= slot.start && time <= slot.end {
                return .inClass(slot.course)
            }
        }
        let previous = timeSlots.last { $0.end <= time }
        let next = timeSlots.first { $0.start > time }

        if previous == nil, let next {
            return .beforeFirst(next: next.course)
        }
        if let previous, next == nil {
            return .afterLast(previous: previous.course)
        }
        return .between(previous: previous?.course, next: next?.course)
    }

    var currentCourseState: CourseState {
        courseState(at: selectedTime)
    }

    // MARK: - Relative Position

    /// X offset (in points) of a given time relative to the center (selectedTime).
    /// Positive = to the right (future), negative = to the left (past).
    func xOffset(for time: Date) -> CGFloat {
        let minutes = time.timeIntervalSince(selectedTime) / 60
        return CGFloat(minutes) * pixelsPerMinute
    }

    // MARK: - Drag

    func onDragStarted() {
        isUserDragging = true
        autoReturnTask?.cancel()
    }

    /// Called incrementally with dx delta (in points). Positive dx = drag right.
    /// invertDirection: if false, drag left → past; if true, drag left → future.
    func onDragChanged(dx: CGFloat, invertDirection: Bool) {
        if !isUserDragging { onDragStarted() }
        let direction: Double = invertDirection ? -1 : 1
        let minutes = Double(dx) / Double(pixelsPerMinute)
        selectedTime = selectedTime.addingTimeInterval(direction * minutes * 60)
    }

    func onDragEnded() {
        let isInsideCourse = timeSlots.contains { selectedTime >= $0.start && selectedTime <= $0.end }
        if !isInsideCourse {
            snapToNearestCourse()
        }
        startAutoReturn()
    }

    func snapToNearestCourse() {
        var nearest = selectedTime
        var minDist: TimeInterval = .infinity
        for slot in timeSlots {
            for boundary in [slot.start, slot.end] {
                let dist = abs(selectedTime.timeIntervalSince(boundary))
                if dist < minDist {
                    minDist = dist
                    nearest = boundary
                }
            }
        }
        withAnimation(.smooth(duration: 0.3)) {
            selectedTime = nearest
        }
    }

    func startAutoReturn() {
        autoReturnTask?.cancel()
        autoReturnTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(.bouncy(duration: 0.6)) {
                isUserDragging = false
                selectedTime = Date()
            }
        }
    }
}
