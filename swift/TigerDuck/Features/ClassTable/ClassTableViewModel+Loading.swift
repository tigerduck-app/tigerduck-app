import Defaults
import SwiftUI

extension ClassTableViewModel {

    func broadcastLocalChange() {
        NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
    }

    func load(authService: AuthService) {
        guard !hasLoaded else { return }
        hasLoaded = true

        let cachedAssignments = DataCache.shared.loadAssignments()
        let merged = buildCourseList(
            DataCache.shared.loadCourses(semester: currentSemester),
            DataCache.shared.loadUserAddedCourses(semester: currentSemester)
        )
        reloadCurrentSemesterCourses()
        assignments = cachedAssignments

        if !merged.isEmpty {
            courses = merged
        }
        if shownPerson != nil || importedTables.shownPerson != nil { showShownTable() }
    }

    func refresh(authService: AuthService) async {
        await fetchData(authService: authService)
    }

    func refreshMissingClassrooms(authService: AuthService) {
        let semester = currentSemester
        Task { [weak self] in
            guard await NetworkMonitor.shared.isReachable(),
                  await AppServiceBridge.refreshCoursesMissingClassroom(semester: semester, authService: authService)
            else { return }
            self?.broadcastLocalChange()
        }
    }

    func triggerRefresh(authService: AuthService, semester: String? = nil) {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task { [weak self] in
            guard let self else { return }
            guard await NetworkMonitor.shared.isReachable() else {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    NTUSTSessionManager.shared.loadingState = .error(String(localized: "error_network_unavailable"))
                    self.isRefreshing = false
                }
                return
            }
            await self.fetchData(authService: authService, semester: semester)
            let latestSemester = CourseSelectionService.currentSemesterCode()
            if latestSemester != self.currentSemester {
                let latestCourses = await AppServiceBridge.fetchCourses(
                    authService: authService,
                    semester: latestSemester
                )
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    let userAdded = DataCache.shared.loadUserAddedCourses(semester: latestSemester)
                    self.currentSemesterCourses = self.buildCourseList(latestCourses, userAdded)
                    self.refreshCourseColors()
                }
            }
            await MainActor.run { [weak self] in
                self?.isRefreshing = false
            }
        }
    }

    private func fetchData(authService: AuthService, semester: String? = nil) async {
        let manager = NTUSTSessionManager.shared
        let targetSemester = semester ?? currentSemester
        let generation = await MainActor.run { authService.loginGeneration }
        guard await NetworkMonitor.shared.isReachable() else {
            await MainActor.run { manager.loadingState = .error(String(localized: "error_network_unavailable")) }
            return
        }
        await MainActor.run { manager.loadingState = .loading }

        MoodleEnrolledCoursesService.dropSharedAnswer()
        async let coursesTask = AppServiceBridge.fetchCourses(
            authService: authService,
            semester: targetSemester,
            forceRefresh: true,
        )
        async let assignmentsTask = AppServiceBridge.fetchAssignments(authService: authService, recheckSubmissions: true)
        async let userAddedTask = AppServiceBridge.refreshUserAddedCourses(
            semester: targetSemester, authService: authService
        )

        let fetchedCourses = await coursesTask
        let fetchedAssignments = await assignmentsTask
        let userAdded = await userAddedTask

        await MainActor.run {
            showFetched(
                buildCourseList(fetchedCourses, userAdded), assignments: fetchedAssignments, of: targetSemester,
                startedUnder: generation, loginGeneration: authService.loginGeneration
            )
        }
    }

    func showFetched(
        _ fetched: [SDCourse], assignments fetchedAssignments: [SDAssignment], of targetSemester: String,
        startedUnder generation: Int, loginGeneration: Int
    ) {
        let manager = NTUSTSessionManager.shared
        guard loginGeneration == generation else {
            manager.loadingState = .loaded
            return
        }
        isUpdatingFromNetwork = true
        if shownPerson == nil, currentSemester == targetSemester { courses = fetched }
        if targetSemester == CourseSelectionService.currentSemesterCode() {
            currentSemesterCourses = fetched
            refreshCourseColors()
        }
        assignments = fetchedAssignments
        manager.loadingState = .loaded
        NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
        isUpdatingFromNetwork = false
    }
}
