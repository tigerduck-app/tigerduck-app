import Foundation

/// Fills the class table: from the stores when it opens, and from the school on a pull, a
/// change of term or a reset. What a fetch saves comes back through the stores.
@MainActor
@Observable
final class ClassTableLoader {
    @ObservationIgnored weak var owner: ClassTableViewModel?
    var isRefreshing = false
    private var hasLoaded = false
    private var hasWarmedCaches = false
    // `nonisolated(unsafe)` lets `deinit`, nonisolated even on a `@MainActor`
    // class, read it to remove the observer. Without `@ObservationIgnored`
    // the `@Observable` macro makes the storage computed and strips the modifier.
    @ObservationIgnored
    private nonisolated(unsafe) var languageObserver: Any?

    init() {
        languageObserver = NotificationCenter.default.addObserver(
            forName: AppConstants.languageDidChange,
            object: nil,
            queue: .main
        ) { _ in
            SchoolRefresh.languageChanged()
        }
    }

    deinit {
        if let observer = languageObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func load() {
        guard !hasLoaded, let table = owner else { return }
        hasLoaded = true

        let cachedAssignments = AssignmentStore.shared.loadAssignments()
        let merged = table.buildCourseList(
            table.courseStore.loadCourses(semester: table.currentSemester),
            table.courseStore.loadUserAddedCourses(semester: table.currentSemester)
        )
        table.today.reload()
        table.assignments = cachedAssignments

        if !merged.isEmpty {
            table.courses = merged
        }
        if table.shownPerson != nil || table.people.store.shownPerson != nil { table.showShownTable() }
    }

    func warmCachesIfNeeded(authService: AuthService) async {
        guard !hasWarmedCaches else { return }
        hasWarmedCaches = true
        await SchoolRefresh.allTerms(authService: authService)
        guard let table = owner else { return }
        table.followNewestSemesterIfUnpicked()
        table.refreshSemesterOptions()
        table.today.reload()
    }

    func refreshSelectedSemester(authService: AuthService) async {
        guard let target = owner?.currentSemester, owner?.shownPerson == nil else { return }
        await SchoolRefresh.courses(target, authService: authService)
        guard let table = owner, table.currentSemester == target else { return }
        let merged = table.buildCourseList(
            table.courseStore.loadCourses(semester: target), table.courseStore.loadUserAddedCourses(semester: target)
        )
        if table.shownPerson == nil, Self.showsChange(merged, over: table.courses) {
            table.courses = merged
        }
        if target == SchoolTerms.current {
            table.today.courses = merged
            table.refreshCourseColors()
        }
    }

    static func showsChange(_ fresh: [CourseStore.Course], over shown: [CourseStore.Course]) -> Bool {
        func drawn(_ courses: [CourseStore.Course]) -> [DrawnCourse] {
            courses.sorted { $0.courseNo < $1.courseNo }.map(DrawnCourse.init)
        }
        return drawn(fresh) != drawn(shown)
    }

    private struct DrawnCourse: Equatable {
        let courseNo, name, customName, instructor, classroom: String
        let credits: Double
        let enrolledCount, maxCount: Int
        let schedule: [Int: [String]]
        let classroomMap: [String: String]
        let moodleIdNumber: String?
        let dimension, allYear, requireOption: String

        init(_ course: CourseStore.Course) {
            courseNo = course.courseNo
            name = course.courseName
            customName = course.customName ?? ""
            instructor = course.instructor
            classroom = course.classroom
            credits = course.credits
            enrolledCount = course.enrolledCount
            maxCount = course.maxCount
            schedule = course.schedule
            classroomMap = course.classroomMap
            moodleIdNumber = course.moodleIdNumber
            dimension = course.dimension
            allYear = course.allYear
            requireOption = course.requireOption
        }
    }

    func refreshMissingClassrooms(authService: AuthService) {
        guard let semester = owner?.currentSemester else { return }
        Task {
            guard await NetworkMonitor.shared.isReachable() else { return }
            await SchoolRefresh.coursesMissingClassroom(semester, authService: authService)
        }
    }

    /// The task keeps the view model alive to the end, so leaving the class table mid-refresh
    /// still ends the loading state and refreshes the current term.
    func triggerRefresh(authService: AuthService, semester: String? = nil) {
        guard !isRefreshing, let table = owner else { return }
        isRefreshing = true
        Task {
            guard await NetworkMonitor.shared.isReachable() else {
                SchoolRefresh.showOffline()
                self.isRefreshing = false
                return
            }
            await self.fetchData(table, authService: authService, semester: semester)
            let latestSemester = SchoolTerms.current
            if latestSemester != table.currentSemester {
                await SchoolRefresh.courses(latestSemester, authService: authService)
                table.today.reload()
                table.refreshCourseColors()
            }
            self.isRefreshing = false
        }
    }

    func refresh(authService: AuthService) async {
        guard let table = owner else { return }
        await fetchData(table, authService: authService)
    }

    private func fetchData(_ table: ClassTableViewModel, authService: AuthService, semester: String? = nil) async {
        let targetSemester = semester ?? table.currentSemester
        let ticket = authService.session.ticket
        guard await SchoolRefresh.begin() else { return }

        SchoolRefresh.dropMoodleCourses()
        async let coursesTask: Void = SchoolRefresh.courses(targetSemester, authService: authService, force: true)
        async let assignmentsTask = SchoolRefresh.assignments(authService: authService)
        async let userAddedTask: Void = SchoolRefresh.userAddedCourses(targetSemester, authService: authService)

        _ = await (coursesTask, assignmentsTask, userAddedTask)
        showFetched(signedOutSince: !authService.session.isCurrent(ticket))
    }

    /// Shows what a fetch saved, read back from the stores, so an edit or another device's change
    /// that landed while it ran stays on screen.
    func showFetched(signedOutSince: Bool) {
        SchoolRefresh.end()
        guard !signedOutSince else { return }
        owner?.reloadFromCache()
    }
}
