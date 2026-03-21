import SwiftUI

@Observable
final class ClassTableViewModel {
    var courses: [SDCourse] = []
    var assignments: [SDAssignment] = []
    var selectedCourse: SDCourse? = nil

    var selectedWeekday: Int? = nil
    var selectedPeriodId: String? = nil

    var currentSemester: String = "114-2"
    let availableSemesters = ["114-2", "114-1", "113-2", "113-1"]

    var showAddCourse = false

    var totalCredits: Int {
        courses.reduce(0) { $0 + $1.credits }
    }

    var selectedCourseTimeRange: String? {
        guard let course = selectedCourse,
              let weekday = selectedWeekday,
              let periods = course.schedule[weekday],
              !periods.isEmpty else {
            return nil
        }
        let order = AppConstants.Periods.defaultVisible + AppConstants.Periods.extended
        let sorted = periods.sorted { a, b in
            (order.firstIndex(of: a) ?? Int.max) < (order.firstIndex(of: b) ?? Int.max)
        }
        guard let firstPeriod = sorted.first,
              let lastPeriod = sorted.last,
              let firstTime = AppConstants.PeriodTimes.mapping[firstPeriod],
              let lastTime = AppConstants.PeriodTimes.mapping[lastPeriod] else {
            return nil
        }
        return "\(firstTime.start) - \(lastTime.end)"
    }

    var todayCourses: [SDCourse] {
        let today = Date().weekdayIndex + 1
        return courses.filter { $0.schedule[today] != nil }
    }

    /// Weekdays that have courses (1=Mon..7=Sun)
    var activeWeekdays: [Int] {
        var days = Set<Int>()
        for course in courses {
            for day in course.schedule.keys {
                days.insert(day)
            }
        }
        // Always show Mon-Fri, add Sat/Sun only if courses exist
        var result = Array(1...5)
        if days.contains(6) { result.append(6) }
        if days.contains(7) { result.append(7) }
        return result.sorted()
    }

    /// Periods that have courses
    var activePeriods: [TimetablePeriod] {
        var periodIds = Set(AppConstants.Periods.defaultVisible)
        for course in courses {
            for periods in course.schedule.values {
                for p in periods {
                    periodIds.insert(p)
                }
            }
        }
        let order = AppConstants.Periods.defaultVisible + AppConstants.Periods.extended
        return order.filter { periodIds.contains($0) }.compactMap { pid in
            TimetablePeriod.all.first { $0.id == pid }
        }
    }

    func course(for weekday: Int, period: String) -> SDCourse? {
        courses.first { course in
            course.schedule[weekday]?.contains(period) == true
        }
    }

    func hasAssignment(for courseNo: String) -> Bool {
        assignments.contains { $0.courseNo == courseNo && !$0.isCompleted }
    }

    func assignmentsFor(courseNo: String) -> [SDAssignment] {
        assignments.filter { $0.courseNo == courseNo && !$0.isCompleted }
    }

    func selectCourse(_ course: SDCourse, weekday: Int, periodId: String) {
        selectedWeekday = weekday
        selectedPeriodId = periodId
        selectedCourse = course
    }

    func refresh() {
        let userAdded = courses.filter { $0.moodleIdNumber == nil }
        courses = MockData.courses + userAdded
        assignments = MockData.assignments
    }

    func load() {
        courses = MockData.courses
        assignments = MockData.assignments
    }
}
