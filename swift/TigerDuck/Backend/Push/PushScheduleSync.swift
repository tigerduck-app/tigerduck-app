import Defaults
import Foundation
import os
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class PushScheduleSync {
    private unowned let app: AppEnvironment

    init(app: AppEnvironment) {
        self.app = app
    }

    func bindPushDelegate(_ delegate: some PushTokenSource) {
        app.pushCoordinator.bindTokenForwarding(delegate)
        delegate.onSyncTrigger = { [weak self] in
            guard let self, self.app.hasCompletedOnboarding else { return .skipped }
            let outcome = await self.app.fullSync.sync(followUpIfBusy: true)
            await self.app.cloudSyncCoordinator.onSyncTrigger()
            return outcome
        }
    }

    #if os(iOS)
    /// A sync trigger's handler calls this after the sync and the widgets' reload, before it
    /// answers the push: iOS may suspend the app once the push is answered.
    func sendAfterSyncTrigger(_ outcome: FullSyncOutcome) async {
        guard Self.sendsScheduleAfterSyncTrigger(
            outcome: outcome, applicationState: UIApplication.shared.applicationState
        ) else { return }
        await NotificationSettingsPushQueue.tail?.value
        await app.pushCoordinator.syncNow { self.pushScheduleInputs() }
    }

    nonisolated static func sendsScheduleAfterSyncTrigger(
        outcome: FullSyncOutcome, applicationState: UIApplication.State
    ) -> Bool {
        outcome == .synced && applicationState == .background
    }
    #endif

    func requestSync() {
        app.pushCoordinator.requestSync { [weak self] in
            guard let self else {
                return ScheduleSyncService.Inputs(
                    courses: [],
                    assignments: [],
                    accentHex: 0x007AFF,
                    classPreparingLeadTime: 0,
                    assignmentLeadTime: 0,
                    showClassPreparing: false,
                    showInClass: false,
                    showAssignmentScenario: false,
                    liveActivityAvailable: false,
                    term: CourseSelectionService.currentSemesterCode()
                )
            }
            return self.pushScheduleInputs()
        }
    }

    private func pushScheduleInputs() -> ScheduleSyncService.Inputs {
        #if os(iOS)
        return ScheduleSyncService.Inputs(
            now: AppClock.now(),
            courses: { self.app.liveActivity.courseProvider.currentCourses(semester: $0) },
            assignments: AssignmentStore.shared.loadAssignments(),
            preferences: app.liveActivity.preferences,
            cloudSyncEnabled: app.cloudSyncEnabled,
            accentHex: app.preferences.accentColorHex,
            calendar: AcademicCalendarStore.shared.calendar,
            optedInHolidayIDs: AcademicCalendarStore.shared.optedInHolidayIDs
        )
        #else
        return ScheduleSyncService.Inputs(
            courses: [],
            assignments: [],
            accentHex: app.preferences.accentColorHex,
            classPreparingLeadTime: 0,
            assignmentLeadTime: 0,
            showClassPreparing: false,
            showInClass: false,
            showAssignmentScenario: false,
            liveActivityAvailable: false,
            term: CourseSelectionService.currentSemesterCode()
        )
        #endif
    }

    func enablePushServer() {
        app.pushCoordinator.enable(requestPermission: true)
        requestSync()
    }

    func refreshMoodleCredentials() async {
        guard await app.authTokenManager.isLoggedIn else { return }
        guard let token = await MoodleTokenService.shared.currentToken(),
              !token.isEmpty else { return }
        let privateToken = KeychainManager.loadString(
            key: AppConstants.KeychainKeys.moodlePrivateToken
        )
        do {
            try await app.pushCoordinator.updateCredentialsIfDue(
                moodleToken: token,
                moodlePrivateToken: privateToken
            )
        } catch {
        }
    }

    func updateServerPushOptOut(_ optOut: Bool) async throws {
        try await app.pushCoordinator.registration.updateServerPushOptOut(optOut)
    }

    func updateBulletinPushEnabled(_ enabled: Bool) async throws {
        try await app.pushCoordinator.registration.updateBulletinPushEnabled(enabled)
    }

    func pushSyncPreferences() {
        let reg = app.pushCoordinator.registration
        Task.detached {
            await reg.updateSyncPreferences()
        }
    }
}
