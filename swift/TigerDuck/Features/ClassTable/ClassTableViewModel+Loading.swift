import Defaults
import SwiftUI

extension ClassTableViewModel {

    func load(authService: AuthService) {
        guard !hasLoaded else { return }
        hasLoaded = true

        let cachedAssignments = AssignmentStore.shared.loadAssignments()
        let merged = buildCourseList(
            courseStore.loadCourses(semester: currentSemester),
            courseStore.loadUserAddedCourses(semester: currentSemester)
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
        Task {
            guard await NetworkMonitor.shared.isReachable() else { return }
            await AppServiceBridge.refreshCoursesMissingClassroom(semester: semester, authService: authService)
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
                _ = await AppServiceBridge.fetchCourses(authService: authService, semester: latestSemester)
                self.reloadCurrentSemesterCourses()
                self.refreshCourseColors()
            }
            await MainActor.run { [weak self] in
                self?.isRefreshing = false
            }
        }
    }

    private func fetchData(authService: AuthService, semester: String? = nil) async {
        let manager = NTUSTSessionManager.shared
        let targetSemester = semester ?? currentSemester
        let ticket = await MainActor.run { authService.session.ticket }
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

        _ = await (coursesTask, assignmentsTask, userAddedTask)
        showFetched(signedOutSince: !authService.session.isCurrent(ticket))
    }

    /// Shows what a fetch saved, read back from the stores, so an edit or another device's change
    /// that landed while it ran stays on screen.
    func showFetched(signedOutSince: Bool) {
        NTUSTSessionManager.shared.loadingState = .loaded
        guard !signedOutSince else { return }
        reloadFromCache()
    }
}
