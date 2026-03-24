import SwiftUI

@Observable
final class ClassTableViewModel {
    var courses: [SDCourse] = []
    var assignments: [SDAssignment] = []
    var selectedCourse: SDCourse? = nil

    var selectedWeekday: Int? = nil
    var selectedPeriodId: String? = nil

    var currentSemester: String = CourseService.currentSemesterCode()
    var availableSemesters: [String] {
        let code = CourseService.currentSemesterCode()
        let yearStr = String(code.dropLast())
        guard let year = Int(yearStr) else { return [code] }
        let sem = String(code.last!)
        var semesters: [String] = []
        // Current + 3 previous semesters
        var y = year
        var s = Int(sem)!
        for _ in 0..<4 {
            semesters.append("\(y)\(s)")
            s -= 1
            if s < 1 { s = 2; y -= 1 }
        }
        return semesters
    }

    var showAddCourse = false

    private var hasLoaded = false
    private var dataObserver: Any?

    init() {
        dataObserver = NotificationCenter.default.addObserver(
            forName: AppConstants.dataDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadFromCache()
        }
    }

    deinit {
        if let observer = dataObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func reloadFromCache() {
        let cached = DataCache.shared.loadCourses()
        let userAdded = courses.filter { $0.moodleIdNumber == nil }
        courses = cached + userAdded
        assignments = DataCache.shared.loadAssignments()
        rebuildColorMap()
    }

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
        let sorted = periods.sortedByPeriodOrder()
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

    var activeWeekdays: [Int] {
        var days = Set<Int>()
        for course in courses {
            for day in course.schedule.keys {
                days.insert(day)
            }
        }
        var result = Array(1...5)
        if days.contains(6) { result.append(6) }
        if days.contains(7) { result.append(7) }
        return result.sorted()
    }

    var activePeriods: [TimetablePeriod] {
        var periodIds = Set(AppConstants.Periods.defaultVisible)
        for course in courses {
            for periods in course.schedule.values {
                for p in periods {
                    periodIds.insert(p)
                }
            }
        }
        let order = AppConstants.Periods.chronologicalOrder
        return order.filter { periodIds.contains($0) }.compactMap { TimetablePeriod.byId[$0] }
    }

    func course(for weekday: Int, period: String) -> SDCourse? {
        courses.first { course in
            course.schedule[weekday]?.contains(period) == true
        }
    }

    func hasAssignment(for courseNo: String) -> Bool {
        assignments.hasUnfinished(for: courseNo)
    }

    func assignmentsFor(courseNo: String) -> [SDAssignment] {
        assignments.unfinished(for: courseNo)
    }

    enum CellRole {
        case empty
        case blockStart(SDCourse, spanCount: Int)
        case blockContinuation
    }

    /// Determine the role of a cell at the given weekday and period index.
    /// Used by TimetableGridView to merge contiguous periods.
    func cellRole(weekday: Int, periodIndex: Int) -> CellRole {
        let periods = activePeriods
        guard periodIndex >= 0, periodIndex < periods.count else { return .empty }

        let period = periods[periodIndex]
        guard let course = course(for: weekday, period: period.id) else { return .empty }

        // Check if previous period has the same course → this is a continuation
        if periodIndex > 0 {
            let prevPeriod = periods[periodIndex - 1]
            if let prevCourse = self.course(for: weekday, period: prevPeriod.id),
               prevCourse.courseNo == course.courseNo {
                return .blockContinuation
            }
        }

        // This is the start of a block — count how many contiguous periods follow
        var span = 1
        var nextIdx = periodIndex + 1
        while nextIdx < periods.count {
            let nextPeriod = periods[nextIdx]
            if let nextCourse = self.course(for: weekday, period: nextPeriod.id),
               nextCourse.courseNo == course.courseNo {
                span += 1
                nextIdx += 1
            } else {
                break
            }
        }

        return .blockStart(course, spanCount: span)
    }

    func selectCourse(_ course: SDCourse, weekday: Int, periodId: String) {
        selectedWeekday = weekday
        selectedPeriodId = periodId
        selectedCourse = course
    }

    private func rebuildColorMap() {
        TigerDuckTheme.buildCourseColorMap(courseNos: courses.map(\.courseNo))
    }

    func load(authService: AuthService) {
        guard !hasLoaded else { return }
        hasLoaded = true

        // Load cached data immediately
        let cachedCourses = DataCache.shared.loadCourses()
        let cachedAssignments = DataCache.shared.loadAssignments()
        if !cachedCourses.isEmpty {
            courses = cachedCourses
            assignments = cachedAssignments
            rebuildColorMap()
        }

        Task {
            await fetchData(authService: authService)
        }
    }

    func refresh(authService: AuthService) async {
        await fetchData(authService: authService)
    }

    private func fetchData(authService: AuthService) async {
        let manager = NTUSTSessionManager.shared
        await MainActor.run { manager.loadingState = .loading }

        async let coursesTask = KMPServiceBridge.fetchCourses(authService: authService)
        async let assignmentsTask = KMPServiceBridge.fetchAssignments(authService: authService)

        let fetchedCourses = await coursesTask
        let fetchedAssignments = await assignmentsTask

        // Merge user-added courses (those without moodleIdNumber)
        let userAdded = courses.filter { $0.moodleIdNumber == nil }

        await MainActor.run {
            courses = fetchedCourses + userAdded
            assignments = fetchedAssignments
            rebuildColorMap()
            manager.loadingState = .loaded
            NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
        }
    }
}
