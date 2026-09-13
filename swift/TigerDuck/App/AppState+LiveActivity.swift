// Live Activity refresh and notification authorization — split out of
// AppState.swift.
//
// iOS only: ActivityKit has no macOS counterpart. Assignment due reminders
// used to be scheduled from here too, via a local UNUserNotificationCenter
// scheduler; that moved server-side, and this file now only requests the
// notification permission the server-sent reminders and Live Activity push
// updates both still need. The whole file is inside `#if os(iOS)` rather
// than each function, so the macOS build sees an empty extension instead of
// a pile of individually-fenced members.

import SwiftUI
import SwiftData
import Defaults
import os
import UserNotifications

extension AppState {

    #if os(iOS)
    // MARK: - Live Activity refresh & notification authorization (iOS only)

    /// Spec §6's answer for this device right now: the user's own switch AND
    /// course sync, through `effectiveLiveActivityEnabled`. What
    /// `LiveActivityCoordinator` asks before keeping, or registering the
    /// update token of, any activity — the ones the server starts included.
    var isLiveActivityAvailable: Bool {
        effectiveLiveActivityEnabled(
            isLiveActivityEnabled: liveActivityPreferences.isLiveActivityEnabled,
            cloudSyncEnabled: cloudSyncEnabled
        )
    }

    /// Recomputes the scenario and pushes it to the coordinator. Safe to call
    /// frequently — the coordinator only issues ActivityKit calls when the
    /// snapshot actually changes.
    func refreshLiveActivity() async {
        let now = AppClock.now()
        let courses = courseProvider.currentCourses()
        let assignments = DataCache.shared.loadAssignments()
        let snapshot = scenarioResolver.resolve(
            courses: courses,
            assignments: assignments,
            preferences: liveActivityPreferences,
            cloudSyncEnabled: cloudSyncEnabled,
            accentHex: accentColorHex,
            now: now,
            calendar: AcademicCalendarStore.shared.calendar,
            optedInHolidayIDs: AcademicCalendarStore.shared.optedInHolidayIDs
        )
        await liveActivityCoordinator.apply(snapshot: snapshot)
        scheduleBoundaryRefresh(
            snapshot: snapshot,
            courses: courses,
            assignments: assignments,
            now: now
        )
    }

    /// While the app is in the foreground, fire a one-shot refresh as soon as
    /// the next meaningful scenario boundary elapses so the Live Activity does
    /// not sit on a stale scenario. When the app is backgrounded the Task is
    /// suspended by iOS; `scenePhase == .active` on return triggers another
    /// refresh, which reschedules this task. This is a best-effort foreground
    /// improvement — true background correctness needs push updates.
    private func scheduleBoundaryRefresh(
        snapshot: LiveActivitySnapshot?,
        courses: [SDCourse],
        assignments: [SDAssignment],
        now: Date
    ) {
        boundaryRefreshTask?.cancel()
        guard let boundary = nextScenarioBoundary(
            snapshot: snapshot,
            courses: courses,
            assignments: assignments,
            now: now
        ) else { return }
        // `boundary` is an app-clock instant; `Task.sleep` runs on the
        // real clock, so under a frozen override the app-clock delta
        // would never elapse and the refresh would re-arm itself
        // forever. Translate to the real instant the boundary maps to
        // before computing the sleep, mirroring the activity end task.
        let realBoundary = AppClock.realTime(forApp: boundary)
        let delay = realBoundary.timeIntervalSinceNow + AppConstants.scenarioBoundarySlackSeconds
        guard delay > 0 else { return }
        boundaryRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.refreshLiveActivity()
        }
    }

    private func nextScenarioBoundary(
        snapshot: LiveActivitySnapshot?,
        courses: [SDCourse],
        assignments: [SDAssignment],
        now: Date
    ) -> Date? {
        var candidates: [Date] = []

        if let target = snapshot?.countdownTarget {
            candidates.append(target)
        }

        let classPrep = liveActivityPreferences.classPreparingLeadTime
        if let nextClassStart = timelineResolver
            .timeline(for: courses, around: now)
            .filter({ $0.start > now })
            .min(by: { $0.start < $1.start })?.start {
            candidates.append(nextClassStart.addingTimeInterval(-classPrep))
            candidates.append(nextClassStart)
        }

        let assignmentLead = liveActivityPreferences.assignmentLiveActivityLeadTime
        if let nextDue = assignments
            .filter({ !$0.isCompleted && $0.dueDate > now })
            .min(by: { $0.dueDate < $1.dueDate })?.dueDate {
            candidates.append(nextDue.addingTimeInterval(-assignmentLead))
            candidates.append(nextDue)
        }

        return candidates.filter { $0 > now }.min()
    }

    /// Prompts the user for notification authorization when, and only when,
    /// they reach an explicit notification-related entry point. Assignment
    /// reminders are scheduled server-side now, but the permission is still
    /// needed — Live Activity push updates and the backend's own reminder
    /// pushes both require it.
    func requestNotificationAuthorization() async {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined:
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                AppLogger.captureError(error, context: ["phase": "notification.requestAuthorization"])
            }
        case .authorized, .provisional, .ephemeral, .denied:
            break
        @unknown default:
            break
        }
    }

    /// Debounces multiple change events (e.g. slider drags or quick toggles)
    /// into a single Live Activity refresh pass.
    func scheduleLiveActivityRefresh() {
        pendingRefreshTask?.cancel()
        pendingRefreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await refreshLiveActivity()
            requestPushScheduleSync()
        }
    }
    #endif // os(iOS) — Live Activity refresh & notification authorization
}
