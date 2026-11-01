import Foundation

struct ClassTableSelection {
    struct ConflictPickerTarget: Identifiable {
        let id = UUID()
        let courses: [CourseStore.Course]
        let weekday: Int
        let periodId: String
    }

    var course: CourseStore.Course?
    var weekday: Int?
    var periodId: String?
    var coursePeriods: [String]?
    var date: Date?
    var slot: CourseTimeSlot?
    var conflictPickerTarget: ConflictPickerTarget?

    var timeRange: String? {
        if let periods = coursePeriods { return CourseStore.Course.timeRange(periods: periods) }
        guard let course, let weekday else { return nil }
        return course.timeRange(for: weekday)
    }

    mutating func select(today course: CourseStore.Course, now: Date) {
        coursePeriods = nil
        periodId = nil
        weekday = now.scheduleWeekday
        date = now
        slot = nil
        self.course = course
    }

    mutating func select(ongoing info: OngoingCourseInfo, now: Date) {
        date = now
        weekday = info.weekday
        periodId = info.firstPeriodId
        coursePeriods = info.periods
        slot = info.slot
        course = info.course
    }
}
