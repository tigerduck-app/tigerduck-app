// Revision polling and background refresh — split out of AppState.swift.
//
// The backend exposes a monotonic revision counter so the app can ask
// "did anything change?" without pulling the whole override set. The
// foreground timer polls it; `backgroundSync` is the BGTaskScheduler
// entry point that fans out to the independent fetches.

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
            // Captive-aware reachability — under a hotel / campus Wi-Fi
            // login page the link is "satisfied" but actual egress is
            // blocked, and the pinned NTUST hosts would hard-fail with
            // an ATS error. Bail early with a clean "no internet"
            // message instead.
            guard await NetworkMonitor.shared.isReachable() else {
                await MainActor.run {
                    sessionManager.loadingState = .error(String(localized: "error_network_unavailable"))
                }
                return
            }

            sessionManager.loadingState = .loading

            // Moodle-direct for the assignment list (proven, correct
            // semester filtering). Backend handles override sync only.
            let fetchedAssignments = await AppServiceBridge.fetchAssignments(authService: authService)
            await syncOverridesFromBackend()

            async let schoolEventsTask = CalendarService.fetchAndParseICS()
            async let coursesTask: Bool = syncCoursesIfAuthenticated()

            let fetchedSchoolEvents = await schoolEventsTask
            _ = await coursesTask

            // Build moodle calendar events from assignments and merge with school events
            let moodleEvents = fetchedAssignments.map {
                SDCalendarEvent(eventId: "moodle-\($0.assignmentId)", title: $0.displayTitle, date: $0.dueDate, source: .moodle)
            }
            // Bail out before persisting if logout cancelled this sync while
            // the network calls were in flight. Without the guard the merged
            // calendar would be written back on top of a freshly purged cache
            // and the previous user's events would resurface.
            guard !Task.isCancelled else { return }

            var calendarCache = DataCache.shared.loadCalendarEvents()
            calendarCache.removeAll { $0.source == .school || $0.source == .moodle }
            calendarCache.append(contentsOf: fetchedSchoolEvents)
            calendarCache.append(contentsOf: moodleEvents)
            DataCache.shared.saveCalendarEvents(calendarCache)

            await MainActor.run {
                guard !Task.isCancelled else { return }
                sessionManager.loadingState = .loaded
                NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
            }
        }
    }

    /// Runs the NTUST-SSO-authenticated portion of background sync
    /// (course list refresh). Factored out so `backgroundSync` can
    /// launch it via `async let` alongside the independent Moodle and
    /// ICS fetches. Returns the auth result purely so the call site
    /// can use it as an `async let` value.
    private func syncCoursesIfAuthenticated() async -> Bool {
        guard await authService.ensureAuthenticated() else { return false }
        _ = await AppServiceBridge.fetchCourses(authService: authService)
        return true
    }
}
