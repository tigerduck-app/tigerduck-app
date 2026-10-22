import SwiftUI
import SwiftData
import Defaults
import os

extension AppState {

    func bindPushDelegate(_ delegate: some PushTokenSource) {
        pushCoordinator.bindTokenForwarding(delegate)
        delegate.onSyncTrigger = { [weak self] in
            guard let self, self.hasCompletedOnboarding else { return .skipped }
            let outcome = await self.syncOverridesFromBackend(followUpIfBusy: true)
            await self.cloudSyncCoordinator.onSyncTrigger()
            return outcome
        }
    }

    #if os(iOS)
    func sendPushScheduleAfterSyncTrigger(_ outcome: FullSyncOutcome) async {
        guard Self.sendsScheduleAfterSyncTrigger(
            outcome: outcome, applicationState: UIApplication.shared.applicationState
        ) else { return }
        await pushCoordinator.syncNow { self.pushScheduleInputs() }
    }

    nonisolated static func sendsScheduleAfterSyncTrigger(
        outcome: FullSyncOutcome, applicationState: UIApplication.State
    ) -> Bool {
        outcome == .synced && applicationState == .background
    }
    #endif

    func requestPushScheduleSync() {
        pushCoordinator.requestSync { [weak self] in
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
            courses: { self.courseProvider.currentCourses(semester: $0) },
            assignments: DataCache.shared.loadAssignments(),
            preferences: liveActivityPreferences,
            cloudSyncEnabled: cloudSyncEnabled,
            accentHex: accentColorHex,
            calendar: AcademicCalendarStore.shared.calendar,
            optedInHolidayIDs: AcademicCalendarStore.shared.optedInHolidayIDs
        )
        #else
        return ScheduleSyncService.Inputs(
            courses: [],
            assignments: [],
            accentHex: accentColorHex,
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
        pushCoordinator.enable(requestPermission: true)
        requestPushScheduleSync()
    }

    func refreshMoodleCredentials() async {
        guard await authTokenManager.isLoggedIn else { return }
        guard let token = await MoodleTokenService.shared.currentToken(),
              !token.isEmpty else { return }
        let privateToken = KeychainManager.loadString(
            key: AppConstants.KeychainKeys.moodlePrivateToken
        )
        do {
            try await pushCoordinator.updateCredentialsIfDue(
                moodleToken: token,
                moodlePrivateToken: privateToken
            )
        } catch {
        }
    }


    func setHolidayNotify(_ notify: Bool, holidayID: Int) {
        guard AcademicCalendarStore.shared.setNotify(notify, forHoliday: holidayID) else {
            return
        }
        #if os(iOS)
        scheduleLiveActivityRefresh()
        #endif
        NotificationCenter.default.post(name: AppConstants.holidayNotifyDidChange, object: nil)
        guard Defaults[.cloudSyncEnabled] else { return }
        enqueueHolidayUpload(holidayID: holidayID)
        revisionPoller.noteActivity()
    }

    func cancelHolidayUploads() {
        HolidayUploadQueue.generation += 1
        HolidayUploadQueue.tail?.cancel()
        HolidayUploadQueue.tail = nil
    }

    func retryUnacknowledgedHolidayOverrides() {
        guard Defaults[.cloudSyncEnabled] else { return }
        for holidayID in AcademicCalendarStore.shared.unacknowledgedHolidayIDs {
            enqueueHolidayUpload(holidayID: holidayID)
        }
    }

    private func enqueueHolidayUpload(holidayID: Int) {
        let previous = HolidayUploadQueue.tail
        let generation = HolidayUploadQueue.generation
        let store = AcademicCalendarStore.shared
        store.setHolidayAcknowledged(false, holidayID: holidayID)
        store.beginHolidayUpload()
        HolidayUploadQueue.tail = Task { [weak self] in
            _ = await previous?.value
            defer { AcademicCalendarStore.shared.endHolidayUpload() }
            guard let self, generation == HolidayUploadQueue.generation else { return }
            let sent = AcademicCalendarStore.shared.optedInHolidayIDs.contains(holidayID)
            do {
                try await self.pushCoordinator.registration.uploadHolidayOverride(
                    holidayID: holidayID, notify: sent
                )
                if AcademicCalendarStore.shared.optedInHolidayIDs.contains(holidayID) == sent {
                    AcademicCalendarStore.shared.setHolidayAcknowledged(true, holidayID: holidayID)
                }
            } catch {
                AppLogger.sync.error(
                    "holiday override upload failed: \(error.localizedDescription, privacy: .private)"
                )
            }
        }
    }

    func updateServerPushOptOut(_ optOut: Bool) async throws {
        try await pushCoordinator.registration.updateServerPushOptOut(optOut)
    }

    func updateBulletinPushEnabled(_ enabled: Bool) async throws {
        try await pushCoordinator.registration.updateBulletinPushEnabled(enabled)
    }

    func pushSyncPreferences() {
        let reg = pushCoordinator.registration
        Task.detached {
            await reg.updateSyncPreferences()
        }
    }
}

@MainActor
private enum HolidayUploadQueue {
    static var tail: Task<Void, Never>?
    static var generation = 0
}
