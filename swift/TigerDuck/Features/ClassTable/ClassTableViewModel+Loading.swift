// Loading and refresh for the class table — split out of
// ClassTableViewModel.swift.
//
// Also the local-change broadcast: Class Table edits have to wake Home
// and the Live Activity coordinator, which they do by posting the same
// `dataDidUpdate` notification a network sync would.

import Defaults
import SwiftUI

extension ClassTableViewModel {

    /// Wakes Home, the Live Activity coordinator, and any other observer
    /// that subscribes to `dataDidUpdate`. Local Class Table edits used to
    /// only update Class Table itself, so renamed/added/deleted courses
    /// would stay stale on Home and on the lock screen until an unrelated
    /// network sync or scene reactivation happened to fire the same
    /// notification. The self-observer guards against the resulting
    /// reload pulling stale persisted state — addCourse / deleteCourse /
    /// confirmRename always write through to DataCache before posting.
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
        // backgroundSync() on app launch handles the network refresh
    }

    func refresh(authService: AuthService) async {
        await fetchData(authService: authService)
    }

    /// Runs on every appearance, not just the first load: any course of the
    /// shown semester that still has no classroom gets looked up again, and
    /// a hit is broadcast so Home and the Live Activity pick it up too.
    func refreshMissingClassrooms() {
        let semester = currentSemester
        Task { [weak self] in
            guard await NetworkMonitor.shared.isReachable(),
                  await AppServiceBridge.refreshCoursesMissingClassroom(semester: semester)
            else { return }
            self?.broadcastLocalChange()
        }
    }

    /// Coalesced fire-and-forget refresh. Designed for pull-to-refresh
    /// where the caller returns immediately (so UIRefreshControl dismisses
    /// its spinner) and the actual fetch continues on a detached Task.
    /// Repeated pulls while a refresh is already in flight are dropped to
    /// prevent two fetches racing on the same caches.
    func triggerRefresh(authService: AuthService) {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task { [weak self] in
            guard let self else { return }
            // Pre-flight gates BOTH the fetchData round-trip and the
            // semester-rollover fetchCourses below — gating only
            // fetchData leaves the rollover path firing pinned-host
            // calls under captive Wi-Fi, surfacing the exact TLS-pin
            // error the pre-flight is meant to hide.
            guard await NetworkMonitor.shared.isReachable() else {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    NTUSTSessionManager.shared.loadingState = .error(String(localized: "error_network_unavailable"))
                    self.isRefreshing = false
                }
                return
            }
            await self.fetchData(authService: authService)
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

    private func fetchData(authService: AuthService) async {
        let manager = NTUSTSessionManager.shared
        let targetSemester = currentSemester
        // Pre-flight here too so the `refresh(authService:)` entry
        // point (used outside triggerRefresh) is also gated. The probe
        // is memoised inside NetworkMonitor so paying for it twice on
        // the triggerRefresh path is effectively free.
        guard await NetworkMonitor.shared.isReachable() else {
            await MainActor.run { manager.loadingState = .error(String(localized: "error_network_unavailable")) }
            return
        }
        await MainActor.run { manager.loadingState = .loading }

        // ClassTable pull-to-refresh is the explicit "show me the
        // latest enrolment" gesture — bust the CourseService cache so
        // add/drop shows up immediately instead of waiting out the 24h
        // TTL that absorbs cheaper background refreshes.
        async let coursesTask = AppServiceBridge.fetchCourses(
            authService: authService,
            semester: targetSemester,
            forceRefresh: true,
        )
        async let assignmentsTask = AppServiceBridge.fetchAssignments(authService: authService)
        // Manual and cross-device courses only ever held the snapshot
        // taken when they were added; the pull is the "latest of
        // everything" gesture, so re-query them too.
        async let userAddedTask = AppServiceBridge.refreshUserAddedCourses(semester: targetSemester)

        let fetchedCourses = await coursesTask
        let fetchedAssignments = await assignmentsTask
        let userAdded = await userAddedTask

        await MainActor.run {
            isUpdatingFromNetwork = true
            courses = buildCourseList(fetchedCourses, userAdded)
            if targetSemester == CourseSelectionService.currentSemesterCode() {
                currentSemesterCourses = courses
                refreshCourseColors()
            }
            assignments = fetchedAssignments
            manager.loadingState = .loaded
            NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
            isUpdatingFromNetwork = false
        }
    }
}
