import Observation

/// Calls `onChange` each time an observable property that `read` touches changes, until it is
/// released or cancelled. The call comes once the change has landed, in a task on the main actor,
/// so changes made together arrive as one.
final class StoreObservation {
    private let read: () -> Void
    private let onChange: () -> Void
    private var isActive = true

    init(read: @escaping () -> Void, onChange: @escaping () -> Void) {
        self.read = read
        self.onChange = onChange
        track()
    }

    func cancel() {
        isActive = false
    }

    private func track() {
        withObservationTracking(read) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isActive else { return }
                self.track()
                self.onChange()
            }
        }
    }
}

/// The revisions of the stores the course and assignment screens draw from: the courses, the
/// assignments and the calendar's events, the colours, the school's course changes and the
/// academic calendar. Reading it inside a `StoreObservation` or a view observes all of them.
struct AppDataRevision: Equatable {
    let courses: Int
    let assignments: Int
    let colors: Int
    let courseChanges: Int
    let calendar: AcademicCalendar

    static var current: AppDataRevision {
        AppDataRevision(
            courses: CourseStore.shared.revision,
            assignments: AssignmentStore.shared.revision,
            colors: CourseColorStore.shared.revision,
            courseChanges: CourseChangeStore.shared.revision,
            calendar: AcademicCalendarStore.shared.calendar
        )
    }
}
