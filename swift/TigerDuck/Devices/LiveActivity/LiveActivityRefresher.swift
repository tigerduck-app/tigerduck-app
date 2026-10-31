// Live Activity refresh, and the notification permission that server-sent reminders and Live
// Activity push updates need. iOS only, since ActivityKit has no macOS counterpart.

#if os(iOS)
import Defaults
import Foundation
import os
import TigerDuckCore
import UserNotifications

/// Decides when to refresh the Live Activity: after a data or settings change, and at the next
/// scenario boundary while the app runs.
@MainActor
final class LiveActivityRefresher {
    let preferences = LiveActivityPreferencesStore()
    let coordinator = LiveActivityCoordinator()
    let courseProvider = CanonicalCourseProvider()
    private let scenarioResolver = LiveActivityScenarioResolver()
    private let timelineResolver = CourseTimelineResolver()
    private unowned let app: AppEnvironment
    private var pendingRefreshTask: Task<Void, Never>?
    private var boundaryRefreshTask: Task<Void, Never>?
    private var preferencesObserver: Any?

    init(app: AppEnvironment) {
        self.app = app
        preferencesObserver = NotificationCenter.default.addObserver(
            forName: AppConstants.liveActivityPreferencesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.scheduleRefresh()
                self?.app.pushSchedule.requestSync()
                guard NotificationSettingsSync.changeNeedsDocumentPush(note.userInfo) else { return }
                self?.app.notificationSettings.schedulePush()
            }
        }
        coordinator.setUpdateTokenRegistrationHandler { [weak self] registration in
            await self?.app.pushCoordinator.registerLiveActivityUpdateToken(registration)
        }
        coordinator.setAvailabilityProvider { [weak self] in
            self?.isAvailable ?? false
        }
        coordinator.setQuietDayProvider { day in
            !AcademicCalendarStore.shared.isClassDay(day)
        }
        coordinator.setAssignmentOutstandingProvider { id in
            LiveActivityScenarioResolver.isOutstanding(
                assignmentId: id,
                in: AssignmentStore.shared.loadAssignments()
            )
        }
        coordinator.setSkippedClassProvider { slotId in
            let courses = CanonicalCourseProvider().currentCourses()
            return CourseTimeSlot.isSkipped(slotId: slotId, in: courses)
                || CourseTimeSlot.hasEnded(slotId: slotId, in: courses, at: AppClock.now())
        }
    }

    deinit {
        pendingRefreshTask?.cancel()
        boundaryRefreshTask?.cancel()
        if let preferencesObserver {
            NotificationCenter.default.removeObserver(preferencesObserver)
        }
    }

    /// Stops the refreshes this sign-in scheduled.
    func cancelRefreshes() {
        pendingRefreshTask?.cancel()
        pendingRefreshTask = nil
        boundaryRefreshTask?.cancel()
        boundaryRefreshTask = nil
    }

    var isAvailable: Bool {
        effectiveLiveActivityEnabled(
            isLiveActivityEnabled: preferences.isLiveActivityEnabled,
            cloudSyncEnabled: app.cloudSyncEnabled
        )
    }

    func refresh() async {
        let now = AppClock.now()
        let courses = courseProvider.currentCourses()
        let assignments = AssignmentStore.shared.loadAssignments()
        let snapshot = scenarioResolver.resolve(
            courses: courses,
            assignments: assignments,
            preferences: preferences,
            cloudSyncEnabled: app.cloudSyncEnabled,
            accentHex: app.preferences.accentColorHex,
            now: now,
            calendar: AcademicCalendarStore.shared.calendar,
            optedInHolidayIDs: AcademicCalendarStore.shared.optedInHolidayIDs
        )
        await coordinator.apply(snapshot: snapshot)
        scheduleBoundaryRefresh(
            snapshot: snapshot,
            courses: courses,
            assignments: assignments,
            now: now
        )
    }

    /// Refreshes again at the next scenario boundary, so the activity does not sit on a stale
    /// scenario. iOS suspends the task in the background; a return to the foreground refreshes.
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
            try? await AppClock.sleep(until: ContinuousClock.now + .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.refresh()
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

        let classPrep = preferences.classPreparingLeadTime
        if let nextClassStart = ClassTimeline.next(after: now, in: timelineResolver.timeline(for: courses, around: now))?.start {
            candidates.append(nextClassStart.addingTimeInterval(-classPrep))
            candidates.append(nextClassStart)
        }

        let assignmentLead = preferences.assignmentLiveActivityLeadTime
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

    func scheduleRefresh(after delay: Duration = .milliseconds(250)) {
        pendingRefreshTask?.cancel()
        pendingRefreshTask = Task { @MainActor in
            try? await AppClock.sleep(until: ContinuousClock.now + delay)
            guard !Task.isCancelled else { return }
            await refresh()
            app.pushSchedule.requestSync()
        }
    }
}
#endif
