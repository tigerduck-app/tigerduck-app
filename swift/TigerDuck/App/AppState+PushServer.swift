// Push-server enrolment and preference propagation — split out of
// AppState.swift.
//
// This is the control plane: binding the APNs delegate, turning the
// server relay on and off, and pushing preference changes up so the
// server stops sending categories the user muted. The data plane — the
// actual override pull/push — is in AppState+BackendSync.swift.

import SwiftUI
import SwiftData
import Defaults
import os

extension AppState {

    // MARK: - Push server integration

    /// Wire the `PushAppDelegate` at app launch so APNs device tokens flow
    /// into `PushRegistrationService`.
    func bindPushDelegate(_ delegate: some PushTokenSource) {
        pushCoordinator.bindTokenForwarding(delegate)
        delegate.onSyncTrigger = { [weak self] in
            await self?.syncOverridesFromBackend()
            await self?.cloudSyncCoordinator.onSyncTrigger()
        }
    }

    /// Sync the next-48h event list to the push server. No-ops when the user
    /// has not enabled server push. Safe to call from any scene / data
    /// transition — `PushCoordinator` debounces bursts into a single POST.
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
                    showAssignmentScenario: false
                )
            }
            #if os(iOS)
            return ScheduleSyncService.Inputs(
                courses: courseProvider.currentCourses(),
                assignments: DataCache.shared.loadAssignments(),
                accentHex: accentColorHex,
                classPreparingLeadTime: liveActivityPreferences.classPreparingLeadTime,
                assignmentLeadTime: liveActivityPreferences.assignmentLiveActivityLeadTime,
                showClassPreparing: liveActivityPreferences.showClassPreparingScenario,
                showInClass: liveActivityPreferences.showInClassScenario,
                showAssignmentScenario: liveActivityPreferences.showAssignmentScenario
            )
            #else
            return ScheduleSyncService.Inputs(
                courses: CanonicalCourseProvider().currentCourses(),
                assignments: DataCache.shared.loadAssignments(),
                accentHex: accentColorHex,
                classPreparingLeadTime: 3600,
                assignmentLeadTime: 8 * 3600,
                showClassPreparing: true,
                showInClass: true,
                showAssignmentScenario: true
            )
            #endif
        }
    }

    /// Enable server push (registers for remote notifications, starts PTS
    /// relay, queues an immediate sync). Call only from explicit user intent
    /// — turning on the Settings toggle. Passes `requestPermission: true`
    /// so the user sees an iOS prompt as feedback for their tap.
    func enablePushServer() {
        Defaults[.pushServerEnabled] = true
        pushCoordinator.enable(requestPermission: true)
        requestPushScheduleSync()
    }

    /// Send the current Moodle token to the backend so the server-side
    /// sync job has a fresh credential. Called on every app foreground.
    /// Fire-and-forget — failure is silent (the sync job just uses the
    /// last-known token until the next successful refresh).
    func refreshMoodleCredentials() async {
        guard await authTokenManager.isLoggedIn else { return }
        guard let token = await MoodleTokenService.shared.currentToken(),
              !token.isEmpty else { return }
        let privateToken = KeychainManager.loadString(
            key: AppConstants.KeychainKeys.moodlePrivateToken
        )
        do {
            _ = try await pushCoordinator.updateCredentials(
                moodleToken: token,
                moodlePrivateToken: privateToken
            )
        } catch {
            // Best-effort — next foreground retries.
        }
    }


    /// Disable server push (tells server to drop the device, stops relay).
    func disablePushServer() async {
        Defaults[.pushServerEnabled] = false
        stopRevisionPolling()
        await pushCoordinator.disable()
    }

    /// Wire the settings toggle to the registration actor. The actor
    /// PATCHes the backend and only then persists the local pref so a
    /// transient failure doesn't leave the UI claiming agreement with
    /// the server. Throws on failure so the caller can roll back.
    func updateServerPushOptOut(_ optOut: Bool) async throws {
        try await pushCoordinator.registration.updateServerPushOptOut(optOut)
    }

    func pushSyncPreferences() {
        let reg = pushCoordinator.registration
        Task.detached {
            await reg.updateSyncPreferences(
                syncCourses: Defaults[.syncCourses],
                syncCourseColors: Defaults[.syncCourseColors],
                syncCourseNames: Defaults[.syncCourseNames],
                syncAssignments: Defaults[.syncAssignments]
            )
        }
    }
}
