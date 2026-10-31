// Live Activity refresh, and the notification permission that server-sent reminders
// and Live Activity push updates need. iOS only, since ActivityKit has no macOS
// counterpart: one `#if os(iOS)` fences the whole body, so macOS sees an empty extension.

import SwiftUI
import SwiftData
import Defaults
import os
import TigerDuckCore
import UserNotifications

extension AppState {

    #if os(iOS)

    var isLiveActivityAvailable: Bool {
        effectiveLiveActivityEnabled(
            isLiveActivityEnabled: liveActivityPreferences.isLiveActivityEnabled,
            cloudSyncEnabled: cloudSyncEnabled
        )
    }

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

    /// not sit on a stale scenario. When the app is backgrounded the Task is
    /// suspended by iOS; `scenePhase == .active` on return triggers another
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
        if let nextClassStart = ClassTimeline.next(after: now, in: timelineResolver.timeline(for: courses, around: now))?.start {
            candidates.append(nextClassStart.addingTimeInterval(-classPrep))
            candidates.append(nextClassStart)
        }

        let assignmentLead = liveActivityPreferences.assignmentLiveActivityLeadTime
        if let nextDue = assignments
            .filter({ LiveActivityScenarioResolver.isOutstanding($0) && $0.dueDate > now })
            .min(by: { $0.dueDate < $1.dueDate })?.dueDate {
            candidates.append(nextDue.addingTimeInterval(-assignmentLead))
            candidates.append(nextDue)
        }

        return candidates.filter { $0 > now }.min()
    }

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

    func scheduleLiveActivityRefresh() {
        pendingRefreshTask?.cancel()
        pendingRefreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await refreshLiveActivity()
            requestPushScheduleSync()
        }
    }
    #endif
}
