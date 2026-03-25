import SwiftUI

@Observable
final class TimeSliderViewModel {
    // MARK: - Data
    private(set) var timeSlots: [CourseTimeSlot] = []
    private(set) var rangeStart: Date = Date()
    private(set) var rangeEnd: Date = Date()

    // MARK: - State
    var selectedTime: Date = Date()
    var isUserDragging: Bool = false

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
        guard let first = timeSlots.first, let last = timeSlots.last else { return }
        rangeStart = first.start.addingTimeInterval(-30 * 60)
        rangeEnd = last.end.addingTimeInterval(30 * 60)
        if !isUserDragging {
            selectedTime = Date()
        }
    }

    // MARK: - Real-time Update

    /// Called by TimelineView every second.
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

    // MARK: - Position Mapping

    func normalizedPosition(for time: Date) -> Double {
        let total = rangeEnd.timeIntervalSince(rangeStart)
        guard total > 0 else { return 0.5 }
        let elapsed = time.timeIntervalSince(rangeStart)
        return min(1, max(0, elapsed / total))
    }

    func time(forNormalized position: Double) -> Date {
        let total = rangeEnd.timeIntervalSince(rangeStart)
        return rangeStart.addingTimeInterval(total * min(1, max(0, position)))
    }

    // MARK: - Drag & Snap

    func onDragStarted() {
        isUserDragging = true
        autoReturnTask?.cancel()
    }

    func onDragEnded() {
        snapToNearestCourse()
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
