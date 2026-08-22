// Live Activity and reminder scheduling — split out of AppState.swift.
//
// iOS only: ActivityKit has no macOS counterpart, and the reminder
// scheduler it drives is built on UNUserNotificationCenter time triggers
// that the Mac app does not register. The whole file is inside
// `#if os(iOS)` rather than each function, so the macOS build sees an
// empty extension instead of a pile of individually-fenced members.

import SwiftUI
import SwiftData
import Defaults
import os

extension AppState {

    #if os(iOS)
    // MARK: - Live Activity / reminder refresh (iOS only)

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
            accentHex: accentColorHex,
            now: now
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

    /// Rebuilds all reminder notifications from the current cached assignments
    /// and the user's selected offsets. The scheduler silently no-ops when
    /// notifications are not authorized, so this never triggers a permission
    /// prompt — call `requestNotificationAuthorization()` from explicit user
    /// intent instead (e.g. when the notifications settings page appears).
    func rescheduleReminders() async {
        let assignments = DataCache.shared.loadAssignments()
        await reminderScheduler.reschedule(
            assignments: assignments,
            // Master switch off -> empty set, which makes the scheduler cancel
            // all pending reminders and bail.
            offsets: liveActivityPreferences.isAssignmentReminderEnabled
                ? liveActivityPreferences.assignmentReminderOffsets
                : []
        )
    }

    /// Prompts the user for notification authorization when, and only when,
    /// they reach an explicit notification-related entry point. After a fresh
    /// grant, immediately rebuild the reminder schedule so the toggles the
    /// user just saw take effect.
    func requestNotificationAuthorization() async {
        let granted = await reminderScheduler.requestAuthorizationIfNeeded()
        if granted {
            await rescheduleReminders()
        }
    }

    /// Debounces multiple change events (e.g. slider drags or quick toggles)
    /// into a single refresh pass so the scheduler is not thrashed.
    ///
    /// - Parameter rescheduleReminderNotifications: pass `false` when the
    ///   trigger only affects the Live Activity snapshot (e.g. accent color).
    ///   Reminder notifications carry only title / course / due date, so
    ///   re-enqueuing them for visual-only changes does no user-visible work
    ///   and just thrashes `UNUserNotificationCenter`.
    func scheduleLiveActivityRefresh(rescheduleReminderNotifications: Bool = true) {
        pendingRefreshTask?.cancel()
        pendingRefreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await refreshLiveActivity()
            if rescheduleReminderNotifications {
                await rescheduleReminders()
            }
            requestPushScheduleSync()
        }
    }
    #endif // os(iOS) — Live Activity / reminder refresh
}
