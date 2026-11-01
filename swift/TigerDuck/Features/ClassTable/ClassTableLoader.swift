import Foundation

@MainActor
@Observable
final class ClassTableLoader {
    @ObservationIgnored weak var owner: ClassTableViewModel?
    let refreshing = StateSignal(false)
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
        await authService.session.withSignIn { await SchoolRefresh.missingTerms(authService: authService, for: $0) }
        guard let table = owner else { return }
        table.followNewestSemesterIfUnpicked()
        table.refreshSemesterOptions()
        table.today.reload()
    }

    func refreshSelectedSemester(authService: AuthService) async {
        guard let target = owner?.currentSemester, owner?.shownPerson == nil else { return }
        await authService.session.withSignIn { await SchoolRefresh.courses(target, authService: authService, for: $0) }
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
        let signIn = authService.session.currentSignIn
        Task {
            guard await NetworkMonitor.shared.isReachable() else { return }
            await SchoolRefresh.coursesMissingClassroom(semester, for: signIn)
        }
    }

    func triggerRefresh(authService: AuthService, semester: String? = nil) {
        guard !refreshing.value, let table = owner else { return }
        refreshing.value = true
        let signIn = authService.session.currentSignIn
        Task {
            guard await NetworkMonitor.shared.isReachable() else {
                SchoolRefresh.showOffline()
                self.refreshing.value = false
                return
            }
            await self.fetchData(table, authService: authService, semester: semester, for: signIn)
            let latestSemester = SchoolTerms.current
            if latestSemester != table.currentSemester {
                await SchoolRefresh.courses(latestSemester, authService: authService, for: signIn)
                table.today.reload()
                table.refreshCourseColors()
            }
            self.refreshing.value = false
        }
    }

    func refresh(authService: AuthService) async {
        guard let table = owner else { return }
        await authService.session.withSignIn { await fetchData(table, authService: authService, for: $0) }
    }

    private func fetchData(
        _ table: ClassTableViewModel, authService: AuthService, semester: String? = nil, for signIn: SignIn
    ) async {
        let targetSemester = semester ?? table.currentSemester
        guard await SchoolRefresh.begin() else { return }

        SchoolRefresh.dropMoodleCourses()
        async let coursesTask: Void = SchoolRefresh.courses(targetSemester, authService: authService, force: true, for: signIn)
        async let assignmentsTask = SchoolRefresh.assignments(authService: authService, for: signIn)
        async let userAddedTask: Void = SchoolRefresh.userAddedCourses(targetSemester, for: signIn)

        _ = await (coursesTask, assignmentsTask, userAddedTask)
        showFetched(signedOutSince: !signIn.isCurrent)
    }

    func showFetched(signedOutSince: Bool) {
        SchoolRefresh.end()
        guard !signedOutSince else { return }
        owner?.reloadFromCache()
    }
}
