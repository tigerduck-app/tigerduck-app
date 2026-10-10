// Push-server control plane: binding the APNs delegate, turning the server relay on and off,
// and pushing preference changes up so the server stops sending muted categories. The data
// plane, the override pull and push, is in AppState+BackendSync.swift.

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

    /// Sync the next-48h event list to the push server. Safe to call from any scene or data
    /// transition: `PushCoordinator` debounces bursts into a single POST.
    ///
    /// While Live Activity is unavailable (its switch or cloud sync is off) the list is empty,
    /// and the server cancels every start this device had queued, so this must also run when
    /// Live Activity becomes unavailable, not only when data changes.
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
                    liveActivityAvailable: false
                )
            }
            #if os(iOS)
            return ScheduleSyncService.Inputs(
                courses: courseProvider.currentCourses(),
                assignments: DataCache.shared.loadAssignments(),
                preferences: liveActivityPreferences,
                cloudSyncEnabled: cloudSyncEnabled,
                accentHex: accentColorHex,
                calendar: AcademicCalendarStore.shared.calendar,
                optedInHolidayIDs: AcademicCalendarStore.shared.optedInHolidayIDs
            )
            #else
            // Empty on a Mac: no push reaches macOS, so a list would only put course and
            // assignment titles on the server, against the user's wish with TigerSync off.
            // It is still sent, to cancel any starts an older build queued for this Mac.
            return ScheduleSyncService.Inputs(
                courses: [],
                assignments: [],
                accentHex: accentColorHex,
                classPreparingLeadTime: 0,
                assignmentLeadTime: 0,
                showClassPreparing: false,
                showInClass: false,
                showAssignmentScenario: false,
                liveActivityAvailable: false
            )
            #endif
        }
    }

    /// Enable server push (registers for remote notifications, starts PTS
    /// relay, queues an immediate sync). Call only from explicit user intent
    /// — the notification step in onboarding. Passes `requestPermission:
    /// true` so the user sees an iOS prompt as feedback for their tap.
    func enablePushServer() {
        pushCoordinator.enable(requestPermission: true)
        requestPushScheduleSync()
    }

    /// Send the current Moodle token to the backend so the server-side
    /// sync job has a fresh credential. Called on every app foreground;
    /// `updateCredentialsIfDue` holds an unchanged token back for an hour.
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
            try await pushCoordinator.updateCredentialsIfDue(
                moodleToken: token,
                moodlePrivateToken: privateToken
            )
        } catch {
            // Best-effort — next foreground retries.
        }
    }


    /// Record whether the user wants class reminders on one holiday.
    ///
    /// The local write is what makes the guard behave. It happens whether or not cloud sync is
    /// on, and whether or not the upload succeeds. The upload only makes the user's other devices
    /// agree, so its failure is logged rather than rolled back: the user's choice on this device
    /// stands either way.
    func setHolidayNotify(_ notify: Bool, holidayID: Int) {
        guard AcademicCalendarStore.shared.setNotify(notify, forHoliday: holidayID) else {
            return
        }
        // The Live Activity, the server's schedule and the widgets all read this set. On iOS,
        // `scheduleLiveActivityRefresh` re-resolves the activity and re-sends the schedule; a
        // Mac has no class reminders. The widgets regenerate on the notification.
        #if os(iOS)
        scheduleLiveActivityRefresh()
        #endif
        NotificationCenter.default.post(name: AppConstants.holidayNotifyDidChange, object: nil)
        guard Defaults[.cloudSyncEnabled] else { return }
        enqueueHolidayUpload(holidayID: holidayID)
    }

    /// Abandon queued holiday uploads. Called at logout: the queue holds the departing account's
    /// edits, and the session they would travel on now belongs to whoever signs in next.
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

    /// Queue one holiday override upload.
    ///
    /// Chained, not fired independently: two taps inside one round trip would otherwise be two
    /// unordered Tasks racing to PATCH the same row, and the server would keep whichever landed
    /// last rather than whichever the user meant last. Each link re-reads the flag when it runs,
    /// so a tap made while an earlier upload was in flight is the one sent, and a retry sends
    /// today's value, not the one that failed.
    private func enqueueHolidayUpload(holidayID: Int) {
        let previous = HolidayUploadQueue.tail
        let generation = HolidayUploadQueue.generation
        // Marked before the request and cleared only on success. Held across
        // the whole chained task, not just the request, so a sync response
        // cannot overwrite the local set between the tap and the upload.
        let store = AcademicCalendarStore.shared
        store.setHolidayAcknowledged(false, holidayID: holidayID)
        store.beginHolidayUpload()
        HolidayUploadQueue.tail = Task { [weak self] in
            _ = await previous?.value
            defer { AcademicCalendarStore.shared.endHolidayUpload() }
            // A logout between queueing and running belongs to the departing
            // account; sending it now would write their choice into whoever
            // signed in since.
            guard let self, generation == HolidayUploadQueue.generation else { return }
            let sent = AcademicCalendarStore.shared.optedInHolidayIDs.contains(holidayID)
            do {
                try await self.pushCoordinator.registration.uploadHolidayOverride(
                    holidayID: holidayID, notify: sent
                )
                // Settled only if the server holds what the user still wants. A toggle made
                // mid-request is queued behind this one and stays protected until it lands;
                // clearing now would let the next sync undo it if that upload failed.
                if AcademicCalendarStore.shared.optedInHolidayIDs.contains(holidayID) == sent {
                    AcademicCalendarStore.shared.setHolidayAcknowledged(true, holidayID: holidayID)
                }
            } catch {
                AppLogger.sync.error(
                    "holiday override upload failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    func updateServerPushOptOut(_ optOut: Bool) async throws {
        try await pushCoordinator.registration.updateServerPushOptOut(optOut)
    }

    /// Wire the bulletin page's toggle to the registration actor, on the
    /// same PATCH-first pattern as `updateServerPushOptOut`: PATCH, then
    /// persist the local Default only on success. The device stays
    /// registered either way — this gates bulletin delivery server-side
    /// only, unlike the old `disablePushServer()` this replaces.
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

/// Serialises holiday-override uploads so they reach the backend in the
/// order the user tapped them.
///
/// A stored property on `AppState` would be the obvious home, but this is an
/// extension and Swift does not allow one there. Static is fine regardless:
/// there is a single `AppState` per process, and the queue's whole job is to
/// order writes to one shared backend row.
@MainActor
private enum HolidayUploadQueue {
    static var tail: Task<Void, Never>?
    /// Bumped at logout. Links queued before it bail instead of sending the
    /// departing account's choices over the next account's session.
    static var generation = 0
}
