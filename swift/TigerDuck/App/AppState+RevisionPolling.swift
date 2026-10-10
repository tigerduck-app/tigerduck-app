// The backend's monotonic revision counter answers "did anything change?" without
// pulling the whole override set; a foreground timer polls it. `backgroundSync` is
// the launch and sign-in sync that fans out to the independent fetches.

import SwiftUI
import SwiftData
import Defaults
import os

extension AppState {

    // MARK: - Revision polling

    /// Start the foreground revision poller. Safe to call repeatedly —
    /// re-entry invalidates the previous timer before scheduling a new one.
    func startRevisionPolling() {
        stopRevisionPolling()
        guard Defaults[.cloudSyncEnabled] else {
            AppLogger.sync.info("[poll] startRevisionPolling skipped — cloudSyncEnabled=false")
            return
        }
        AppLogger.sync.info("[poll] startRevisionPolling — scheduling 10s timer")
        revisionPollTimer = Timer.scheduledTimer(
            withTimeInterval: 10,
            repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.pollRevision()
            }
        }
    }

    /// Stop the foreground revision poller (e.g. when the app backgrounds).
    func stopRevisionPolling() {
        if revisionPollTimer != nil {
            AppLogger.sync.info("[poll] stopRevisionPolling — timer invalidated")
        }
        revisionPollTimer?.invalidate()
        revisionPollTimer = nil
    }

    /// Single poll tick: fetch the lightweight revision endpoint, compare
    /// with ``_lastKnownRevision``, and trigger a full sync when the
    /// server is ahead.
    private func pollRevision() async {
        guard Defaults[.cloudSyncEnabled] else {
            AppLogger.sync.info("[poll] tick skipped — cloudSyncEnabled=false")
            return
        }
        guard await authTokenManager.isLoggedIn else {
            AppLogger.sync.info("[poll] tick skipped — not logged in")
            return
        }
        AppLogger.sync.info("[poll] tick — fetching revision (lastKnown=\(self._lastKnownRevision))")
        do {
            let serverRevision = try await pushCoordinator.fetchRevision()
            AppLogger.sync.info("[poll] server revision=\(serverRevision) lastKnown=\(self._lastKnownRevision)")
            if serverRevision > _lastKnownRevision {
                AppLogger.sync.info("[poll] revision changed — triggering full sync")
                await syncOverridesFromBackend()
                await cloudSyncCoordinator.onRevisionChanged()
            }
        } catch {
            AppLogger.sync.info("[poll] tick failed: \(error, privacy: .public)")
        }
    }

    /// Background sync all data on app launch.
    ///
    /// Three independent tracks run in parallel. Moodle rides a long-
    /// lived OIDC token (no NTUST SSO dependency), the ICS calendar is
    /// public, and the courses track owns its own auth check so Moodle
    /// and ICS are never held up behind `ensureAuthenticated()`.
    func backgroundSync() {
        guard hasCompletedOnboarding else { return }
        startRevisionPolling()
        syncTask?.cancel()
        syncTask = Task {
            // Behind a hotel or campus Wi-Fi login page the link is "satisfied" but
            // egress is blocked, and the pinned NTUST hosts would hard-fail with an ATS
            // error. Bail early with a clean "no internet" message instead.
            guard await NetworkMonitor.shared.isReachable() else {
                await MainActor.run {
                    sessionManager.loadingState = .error(String(localized: "error_network_unavailable"))
                }
                return
            }

            sessionManager.loadingState = .loading

            // Moodle-direct for the assignment list (proven, correct
            // semester filtering). Backend handles override sync only.
            _ = await AppServiceBridge.fetchAssignments(authService: authService)
            await syncOverridesFromBackend()

            async let schoolEventsTask = CalendarService.fetchAndParseICS()
            async let coursesTask: Bool = syncCoursesIfAuthenticated()

            let fetchedSchoolEvents = await schoolEventsTask
            _ = await coursesTask

            // Bail out before persisting if logout cancelled this sync mid-flight. The
            // merged calendar would otherwise land on the freshly purged cache and
            // resurface the previous user's events.
            guard !Task.isCancelled else { return }

            // The assignment round rebuilt the Moodle rows; only the school's change here.
            var calendarCache = DataCache.shared.loadCalendarEvents()
            calendarCache.removeAll { $0.source == .school }
            calendarCache.append(contentsOf: fetchedSchoolEvents)
            DataCache.shared.saveCalendarEvents(calendarCache)

            await MainActor.run {
                guard !Task.isCancelled else { return }
                sessionManager.loadingState = .loaded
                NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
            }
        }
    }

    /// Runs the course list refresh of background sync. Factored out so `backgroundSync` can
    /// launch it via `async let` alongside the independent Moodle and ICS fetches. It signs in
    /// to SSO only when the course-selection list is due; the rest needs no school session.
    private func syncCoursesIfAuthenticated() async -> Bool {
        guard let studentId = authService.storedStudentId else { return false }
        let semester = CourseSelectionService.currentSemesterCode()
        if CourseSelectionService.needsSchoolSession(studentId: studentId, semester: semester) {
            guard await authService.ensureAuthenticated() else { return false }
        } else {
            await authService.ensureBackendSignedIn()
        }
        _ = await AppServiceBridge.fetchCourses(authService: authService, semester: semester)
        return true
    }
}
