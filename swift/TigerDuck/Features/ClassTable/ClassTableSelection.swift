import Foundation

struct ClassTableSelection {
    struct ConflictPickerTarget: Identifiable {
        let id = UUID()
        let courses: [CourseStore.Course]
        let weekday: Int
        let periodId: String
    }

    struct ClubPickerTarget: Identifiable {
        let id = UUID()
        let clubs: [ClubOccurrence]
    }

    var course: CourseStore.Course?
    var weekday: Int?
    var periodId: String?
    var coursePeriods: [String]?
    var date: Date?
    var currentClassSlot: CourseTimeSlot?
    var conflictPickerTarget: ConflictPickerTarget?
    var club: ClubOccurrence?
    var clubPicker: ClubPickerTarget?

    var times: (start: String, end: String)? {
        if let periods = coursePeriods { return CourseStore.Course.times(periods: periods) }
        guard let course, let weekday else { return nil }
        return course.times(for: weekday)
    }

    mutating func select(today course: CourseStore.Course, now: Date) {
        coursePeriods = nil
        periodId = nil
        weekday = now.scheduleWeekday
        date = now
        currentClassSlot = nil
        self.course = course
    }

    mutating func select(ongoing info: OngoingCourseInfo, now: Date) {
        date = now
        weekday = info.weekday
        periodId = info.firstPeriodId
        coursePeriods = info.periods
        currentClassSlot = info.slot
        course = info.course
    }
}
