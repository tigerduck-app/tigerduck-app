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

    // The view model owns the loader, so it outlives every call into it.
    private var table: ClassTableViewModel { owner! }

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
        guard !hasLoaded else { return }
        hasLoaded = true
        let table = table

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
        let table = table
        table.followNewestSemesterIfUnpicked()
        table.refreshSemesterOptions()
        table.today.reload()
    }

    func refreshSelectedSemester(authService: AuthService) async {
        guard table.shownPerson == nil else { return }
        let target = table.currentSemester
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
        let semester = table.currentSemester
        Task {
            guard await NetworkMonitor.shared.isReachable() else { return }
            await SchoolRefresh.coursesMissingClassroom(semester, authService: authService)
        }
    }

    func triggerRefresh(authService: AuthService, semester: String? = nil) {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task { [weak self] in
            guard let self else { return }
            guard await NetworkMonitor.shared.isReachable() else {
                SchoolRefresh.showOffline()
                self.isRefreshing = false
                return
            }
            await self.fetchData(authService: authService, semester: semester)
            let latestSemester = SchoolTerms.current
            if latestSemester != self.table.currentSemester {
                await SchoolRefresh.courses(latestSemester, authService: authService)
                self.table.today.reload()
                self.table.refreshCourseColors()
            }
            self.isRefreshing = false
        }
    }

    func refresh(authService: AuthService) async {
        await fetchData(authService: authService)
    }

    private func fetchData(authService: AuthService, semester: String? = nil) async {
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
        table.reloadFromCache()
    }
}
