// Reads and writes the `notification` settings-document namespace —
// split out of AppState.swift like the other sync surfaces
// (AppState+PushServer.swift, AppState+BackendSync.swift).
//
// This owns exactly two of the document's three sections: `assignments`
// and `live_activity` (mapping fixed by the v2.1.0 sync-notifications
// design spec §4.6 — see `NotificationSettingsSync.LocalPreferences`
// below; do not add fields beyond that table). The third section,
// `courses`, belongs to a separate feature. Every write here round-trips
// it unchanged: read whatever the server currently holds, splice in
// `assignments` + `live_activity`, re-encode `courses` exactly as read.
// Losing it would silently turn off the user's class reminders with
// nothing on screen to show it.
//
// iOS only: every field this syncs lives on `LiveActivityPreferencesStore`,
// which `AppState` only instantiates under `#if os(iOS)`
// (`AppState+LiveActivity.swift`).

import Foundation
import Defaults
import os

extension AppState {
    #if os(iOS)

    // MARK: - Public entry points

    /// Pushes this device's `assignments` + `live_activity` preferences to
    /// the backend. Gated on `cloudSyncEnabled` only — the per-category
    /// device switches (`syncAssignmentReminders` / `syncLiveActivity`)
    /// don't exist yet; a later task adds them and the per-section gating
    /// that goes with them.
    ///
    /// Fire-and-forget: invoked from the debounced
    /// `scheduleNotificationSettingsPush()` below, with no caller awaiting
    /// the result, so failures are logged rather than thrown further.
    func pushNotificationSettings() async {
        let atm = authTokenManager
        let client = SettingsDocumentClient(
            authHeaderProvider: { await atm.authorizationHeader() }
        )
        let local = NotificationSettingsSync.LocalPreferences(from: liveActivityPreferences)
        do {
            try await NotificationSettingsSync.push(
                local: local,
                client: client,
                cloudSyncEnabled: Defaults[.cloudSyncEnabled]
            )
        } catch {
            AppLogger.sync.error(
                "pushNotificationSettings failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Fetches the backend's `notification` document and applies its
    /// `assignments` + `live_activity` sections onto
    /// `liveActivityPreferences` — the reverse of `pushNotificationSettings()`,
    /// e.g. so a reminder configured on another device shows up here.
    /// Gated on `cloudSyncEnabled` for the same reason the push is: with
    /// sync off, this document shouldn't be touched in either direction.
    /// Not wired to an automatic call site yet (e.g. app launch / login);
    /// available for a later task to invoke.
    func pullNotificationSettings() async {
        let atm = authTokenManager
        let client = SettingsDocumentClient(
            authHeaderProvider: { await atm.authorizationHeader() }
        )
        do {
            guard let document = try await NotificationSettingsSync.pull(
                client: client,
                cloudSyncEnabled: Defaults[.cloudSyncEnabled]
            ) else { return }
            NotificationSettingsSync.apply(document, to: liveActivityPreferences)
        } catch {
            AppLogger.sync.error(
                "pullNotificationSettings failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Debounced push trigger

    /// Debounces bursts of `liveActivityPreferencesDidChange` (e.g. a
    /// slider drag posts many in a row) into a single push, reusing
    /// `scheduleLiveActivityRefresh`'s 250 ms convention
    /// (`AppState+LiveActivity.swift:146-157`). Kept as its own timer
    /// rather than folded into that function: `scheduleLiveActivityRefresh`
    /// also runs off `dataDidUpdate` and `courseSkipStateDidChange`, neither
    /// of which is a preference change this document cares about — piggy-
    /// backing on it would fire a settings PUT on every data sync, which is
    /// exactly the "API call on every tick" the task brief says to avoid.
    func scheduleNotificationSettingsPush() {
        NotificationSettingsPushDebounce.pendingTask?.cancel()
        NotificationSettingsPushDebounce.pendingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.pushNotificationSettings()
        }
    }
    #endif // os(iOS)
}

/// Holds the debounce timer for `scheduleNotificationSettingsPush()`.
///
/// A stored property on `AppState` would be the obvious home, but this is
/// an extension and Swift does not allow one there — same constraint
/// `HolidayUploadQueue` documents in `AppState+PushServer.swift`. Static is
/// fine regardless: there is a single `AppState` per process.
@MainActor
private enum NotificationSettingsPushDebounce {
    static var pendingTask: Task<Void, Never>?
}

// MARK: - Testable sync logic

/// Push/pull logic for the `notification` settings document, factored out
/// of the `AppState` extension above so it is unit-testable without
/// constructing a full `AppState` — nothing in this test target does that
/// (`AppState` pulls in SwiftData, `AuthService`, live push registration,
/// etc.). Mirrors how `ScheduleSyncService` sits underneath
/// `AppState+PushServer.swift`.
///
/// `nonisolated`, matching `NotificationSettingsDocument` and
/// `SettingsWriteResult`: this has no actor affinity of its own beyond the
/// one function (`apply`) that touches the `@MainActor`
/// `LiveActivityPreferencesStore`.
nonisolated enum NotificationSettingsSync {
    static let namespace = "notification"

    /// A neutral, inert stand-in for `courses`, used only when the user has
    /// no `notification` document at all yet (a brand-new account that has
    /// never synced any of the three sections). Never used once a document
    /// exists — from that point on, `courses` is always whatever was last
    /// read, verbatim. `enabled: false` / no offsets rather than guessing
    /// at the course-reminder feature's real defaults, which this task
    /// does not own.
    static let defaultCourses = NotificationSettingsDocument.Courses(
        enabled: false,
        reminderOffsetsMinutes: []
    )

    /// The retried write also ended in conflict. Per the task brief: adopt
    /// the server's version and retry once, but never loop forever.
    enum SyncError: Error, Equatable, Sendable {
        case conflictNotResolved
    }

    /// Local preference snapshot, decoupled from `LiveActivityPreferencesStore`
    /// so tests can construct one directly instead of standing up a real
    /// store (which reads/writes `Defaults` / `UserDefaults`).
    ///
    /// Field mapping is fixed by the task brief's table — do not add or
    /// infer fields beyond these seven:
    ///
    /// | local                             | document field                               |
    /// |------------------------------------|-----------------------------------------------|
    /// | `isAssignmentReminderEnabled`       | `assignments.enabled`                          |
    /// | `assignmentReminderOffsets`         | `assignments.reminder_offsets_hours`           |
    /// | `showClassPreparingScenario`        | `live_activity.show_class_preparing`           |
    /// | `showInClassScenario`               | `live_activity.show_in_class`                  |
    /// | `showAssignmentScenario`            | `live_activity.show_assignment`                |
    /// | `classPreparingLeadTime`            | `live_activity.class_preparing_lead_seconds`   |
    /// | `assignmentLiveActivityLeadTime`    | `live_activity.assignment_lead_seconds`        |
    struct LocalPreferences: Equatable, Sendable {
        var isAssignmentReminderEnabled: Bool
        var assignmentReminderOffsets: Set<AssignmentReminderOffset>
        var showClassPreparingScenario: Bool
        var showInClassScenario: Bool
        var showAssignmentScenario: Bool
        var classPreparingLeadTime: TimeInterval
        var assignmentLiveActivityLeadTime: TimeInterval

        init(
            isAssignmentReminderEnabled: Bool,
            assignmentReminderOffsets: Set<AssignmentReminderOffset>,
            showClassPreparingScenario: Bool,
            showInClassScenario: Bool,
            showAssignmentScenario: Bool,
            classPreparingLeadTime: TimeInterval,
            assignmentLiveActivityLeadTime: TimeInterval
        ) {
            self.isAssignmentReminderEnabled = isAssignmentReminderEnabled
            self.assignmentReminderOffsets = assignmentReminderOffsets
            self.showClassPreparingScenario = showClassPreparingScenario
            self.showInClassScenario = showInClassScenario
            self.showAssignmentScenario = showAssignmentScenario
            self.classPreparingLeadTime = classPreparingLeadTime
            self.assignmentLiveActivityLeadTime = assignmentLiveActivityLeadTime
        }

        @MainActor
        init(from store: LiveActivityPreferencesStore) {
            self.init(
                isAssignmentReminderEnabled: store.isAssignmentReminderEnabled,
                assignmentReminderOffsets: store.assignmentReminderOffsets,
                showClassPreparingScenario: store.showClassPreparingScenario,
                showInClassScenario: store.showInClassScenario,
                showAssignmentScenario: store.showAssignmentScenario,
                classPreparingLeadTime: store.classPreparingLeadTime,
                assignmentLiveActivityLeadTime: store.assignmentLiveActivityLeadTime
            )
        }

        /// `AssignmentReminderOffset` → `assignments.reminder_offsets_hours`.
        /// Only whole-hour offsets (`hr48`…`hr1`) are representable in a
        /// field literally named "hours"; the four sub-hour cases
        /// (`min30`/`min15`/`min10`/`min5`) would collide on truncation
        /// (all four → `0`), silently merging distinct user choices into
        /// one value. They are left out of this cross-device mirror rather
        /// than encoded lossily — this only builds the outgoing document
        /// and never mutates the local offsets set, so the on-device
        /// schedule is unaffected either way. Sorted descending for a
        /// deterministic, readable array (`Set` iteration order is not
        /// stable).
        var reminderOffsetsHours: [Int] {
            assignmentReminderOffsets
                .compactMap { offset -> Int? in
                    let seconds = offset.timeInterval
                    guard seconds >= 3600, seconds.truncatingRemainder(dividingBy: 3600) == 0 else {
                        return nil
                    }
                    return Int(seconds / 3600)
                }
                .sorted(by: >)
        }

        var assignmentsSection: NotificationSettingsDocument.Assignments {
            .init(enabled: isAssignmentReminderEnabled, reminderOffsetsHours: reminderOffsetsHours)
        }

        var liveActivitySection: NotificationSettingsDocument.LiveActivity {
            .init(
                showClassPreparing: showClassPreparingScenario,
                showInClass: showInClassScenario,
                showAssignment: showAssignmentScenario,
                classPreparingLeadSeconds: Int(classPreparingLeadTime),
                assignmentLeadSeconds: Int(assignmentLiveActivityLeadTime)
            )
        }
    }

    // MARK: - Push

    /// Read-modify-write cycle for `assignments` + `live_activity`.
    /// `courses` always travels back exactly as read. On a 409, adopts the
    /// server's document (so a concurrent `courses` write is preserved)
    /// and its revision, then retries exactly once — never loops.
    static func push(
        local: LocalPreferences,
        client: SettingsDocumentClient,
        cloudSyncEnabled: Bool
    ) async throws {
        guard cloudSyncEnabled else { return }

        var courses = defaultCourses
        var baseRevision: Int?

        if let (data, revision) = try await client.read(namespace: namespace) {
            // If this can't be decoded, the safest move is to abort rather
            // than guess at a `courses` value — see `defaultCourses`.
            let existing = try JSONDecoder().decode(NotificationSettingsDocument.self, from: data)
            courses = existing.courses
            baseRevision = revision
        }

        var attempt = 0
        while true {
            let document = NotificationSettingsDocument(
                assignments: local.assignmentsSection,
                courses: courses,
                liveActivity: local.liveActivitySection
            )
            let body = try JSONEncoder().encode(document)
            let result = try await client.write(namespace: namespace, document: body, baseRevision: baseRevision)

            switch result {
            case .written:
                return
            case .conflict(let serverDocument, let serverRevision):
                attempt += 1
                guard attempt <= 1 else {
                    throw SyncError.conflictNotResolved
                }
                let decoded = try JSONDecoder().decode(NotificationSettingsDocument.self, from: serverDocument)
                courses = decoded.courses
                baseRevision = serverRevision
            }
        }
    }

    // MARK: - Pull

    /// Fetches the current `notification` document. `nil` when sync is off
    /// or the user has never written to this namespace — both normal, not
    /// errors.
    static func pull(
        client: SettingsDocumentClient,
        cloudSyncEnabled: Bool
    ) async throws -> NotificationSettingsDocument? {
        guard cloudSyncEnabled else { return nil }
        guard let (data, _) = try await client.read(namespace: namespace) else { return nil }
        return try JSONDecoder().decode(NotificationSettingsDocument.self, from: data)
    }

    /// Reverse of `LocalPreferences` above. A `reminder_offsets_hours`
    /// entry with no matching whole-hour `AssignmentReminderOffset` case
    /// (an offset a newer client added, outside this build's set) is
    /// skipped rather than failing the whole pull — the same forward-
    /// compatibility stance as `NotificationSettingsDocument`'s own
    /// decoding. Sub-hour offsets this device may have selected locally
    /// are never round-tripped through this field at all (see
    /// `reminderOffsetsHours` above), so a pull has nothing to say about
    /// them one way or the other and leaves them alone — only the 7 mapped
    /// fields are overwritten.
    @MainActor
    static func apply(_ document: NotificationSettingsDocument, to store: LiveActivityPreferencesStore) {
        let offsets = Set(
            document.assignments.reminderOffsetsHours.compactMap { hours in
                AssignmentReminderOffset.allCases.first { $0.timeInterval == TimeInterval(hours) * 3600 }
            }
        )
        let liveActivity = document.liveActivity
        store.applyFromNotificationSettingsDocument(
            isAssignmentReminderEnabled: document.assignments.enabled,
            assignmentReminderOffsets: offsets,
            showClassPreparingScenario: liveActivity?.showClassPreparing ?? store.showClassPreparingScenario,
            showInClassScenario: liveActivity?.showInClass ?? store.showInClassScenario,
            showAssignmentScenario: liveActivity?.showAssignment ?? store.showAssignmentScenario,
            classPreparingLeadTime: liveActivity.map { TimeInterval($0.classPreparingLeadSeconds) }
                ?? store.classPreparingLeadTime,
            assignmentLiveActivityLeadTime: liveActivity.map { TimeInterval($0.assignmentLeadSeconds) }
                ?? store.assignmentLiveActivityLeadTime
        )
    }
}
