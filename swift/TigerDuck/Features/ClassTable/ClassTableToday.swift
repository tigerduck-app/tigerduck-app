import Foundation

/// The current term's classes for Today's classes above the table, whichever term the table
/// shows: today's courses and the ones running now.
@MainActor
@Observable
final class ClassTableToday {
    var courses: [CourseStore.Course] = []
    private var classDayRevision = 0
    @ObservationIgnored private let minuteTicker = MinuteTicker()
    @ObservationIgnored private let isClassDay: (Date) -> Bool
    // `nonisolated(unsafe)` lets `deinit`, nonisolated even on a `@MainActor`
    // class, read it to remove the observer. Without `@ObservationIgnored`
    // the `@Observable` macro makes the storage computed and strips the modifier.
    @ObservationIgnored
    private nonisolated(unsafe) var holidayObserver: Any?

    init(isClassDay: @escaping (Date) -> Bool) {
        self.isClassDay = isClassDay
        holidayObserver = NotificationCenter.default.addObserver(
            forName: AppConstants.holidayNotifyDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.classDayRevision &+= 1 }
        }
    }

    deinit {
        if let observer = holidayObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func reload() {
        courses = CanonicalCourseProvider().currentCourses()
    }

    var todayCourses: [CourseStore.Course] {
        _ = AppClockState.shared.version
        _ = minuteTicker.tick
        _ = classDayRevision
        guard isClassDay(AppClock.now()) else { return [] }
        return courses.coursesForToday()
    }

    func ongoingCourses(changes: SchoolCalendar.Changes) -> [OngoingCourseInfo] {
        _ = AppClockState.shared.version
        _ = minuteTicker.tick
        return courses.ongoingCourses(at: AppClock.now(), changes: changes)
    }
}
