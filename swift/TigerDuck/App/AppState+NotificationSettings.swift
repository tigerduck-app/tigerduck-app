// Reads and writes the `notification` settings-document namespace —
// split out of AppState.swift like the other sync surfaces
// (AppState+PushServer.swift, AppState+BackendSync.swift).
//
// This owns exactly two of the document's keys — `assignments` and
// `live_activity` (mapping fixed by the v2.1.0 sync-notifications design
// spec §4.6 — see `NotificationSettingsSync.LocalPreferences` below; do not
// add fields beyond that table). Everything else in the document belongs to
// somebody else: `courses` to the course-reminder feature, and whatever
// sections Android (spec W6) or a future build add to the same namespace.
//
// Writes therefore **merge at the JSON level** rather than re-encoding a
// typed struct: read whatever the server currently holds as a dictionary,
// splice the two keys this app owns over it, and PUT the result. Every
// other key — top-level or nested inside a section — travels back exactly
// as it arrived, including keys this build has never heard of. Re-encoding
// a typed struct instead would silently delete them, and for `courses` that
// means silently turning off the user's class reminders with nothing on
// screen to show it.
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
    /// the backend. Gated on `cloudSyncEnabled`, and per-section on the
    /// device switches `syncAssignmentReminders` / `syncLiveActivity`: a
    /// section whose switch is off is left exactly as the server currently
    /// holds it rather than overwritten with the local value, and if both
    /// are off nothing is sent at all (see `NotificationSettingsSync.push`).
    ///
    /// Two preconditions decided up front rather than read off a failure,
    /// matching `syncOverridesFromBackend` (`AppState+BackendSync.swift`):
    /// cloud sync must be on, and there must be a session. Firing
    /// unauthenticated and reading the 401 as the answer is exactly what
    /// `PushAPIClient.hasAuthSession()` documents you must not do — "a 401
    /// is also what a revoked or expired session looks like", and those
    /// deserve different handling.
    ///
    /// Failures are logged rather than thrown: no caller awaits this. They
    /// are not, however, dropped — `Defaults[.notificationSettingsPushPending]`
    /// stays set until a write actually lands **and** nothing has changed
    /// locally since, and `retryUnacknowledgedNotificationSettings()`
    /// re-runs the push at the next full sync. Same mark-before /
    /// clear-on-settled shape as the holiday-override queue
    /// (`AppState+PushServer.swift`).
    func pushNotificationSettings() async {
        guard Defaults[.cloudSyncEnabled] else { return }
        guard await authTokenManager.isLoggedIn else { return }

        let atm = authTokenManager
        let client = SettingsDocumentClient(
            authHeaderProvider: { await atm.authorizationHeader() }
        )
        let local = NotificationSettingsSync.LocalPreferences(from: liveActivityPreferences)
        do {
            let written = try await NotificationSettingsSync.push(
                local: local,
                client: client,
                cloudSyncEnabled: Defaults[.cloudSyncEnabled],
                syncAssignmentRemindersEnabled: Defaults[.syncAssignmentReminders],
                syncLiveActivityEnabled: Defaults[.syncLiveActivity]
            )
            // Settled only if the store still matches what was just sent. A
            // preference change that arrived while this request was in
            // flight is already queued behind it
            // (`enqueueNotificationSettingsPush`'s chain) and must stay
            // marked pending until *that* push lands — clearing here would
            // let a kill in the next 250 ms lose it. Mirrors
            // `enqueueHolidayUpload`'s re-read-and-compare
            // (`AppState+PushServer.swift`).
            if NotificationSettingsSync.canClearPendingMarker(
                written: written,
                sent: local,
                current: .init(from: liveActivityPreferences)
            ) {
                Defaults[.notificationSettingsPushPending] = false
            }
        } catch {
            AppLogger.sync.error(
                "pushNotificationSettings failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// The one routine that reads the `notification` document: it reads
    /// it, adopts each synced section the server has, and writes only the
    /// sections it lacks (`NotificationSettingsSync.reconcile`). Runs as a
    /// link on `NotificationSettingsPushQueue`, so it never interleaves
    /// with a push's read-modify-write and never outlives a logout.
    ///
    /// Called once after upgrade (`NotificationSettingsSeedMigration`),
    /// after each full sync that lands (`syncOverridesFromBackend`), when
    /// either notification settings screen opens, and after sign-in.
    /// Sign-in comes here rather than to a push on purpose: a push would
    /// write this device's values over the account's document — values a
    /// previous account may have left on the device — where reading first
    /// adopts what the account already holds.
    ///
    /// A local edit the server has not acknowledged wins: the routine does
    /// not read over it, and that edit's push runs instead. Gated on
    /// `cloudSyncEnabled` and on having a session for the same reasons the
    /// push is. `onSettled` runs only once the document has actually been
    /// read and every synced section settled.
    func reconcileNotificationSettings(onSettled: (@MainActor () -> Void)? = nil) {
        NotificationSettingsPushQueue.enqueueReconcile { [weak self] isCurrent in
            guard let self, Defaults[.cloudSyncEnabled] else { return }
            guard await self.authTokenManager.isLoggedIn, isCurrent() else { return }

            let atm = self.authTokenManager
            let client = SettingsDocumentClient(
                authHeaderProvider: { await atm.authorizationHeader() }
            )
            do {
                let outcome = try await NotificationSettingsSync.reconcile(
                    store: self.liveActivityPreferences,
                    client: client,
                    cloudSyncEnabled: Defaults[.cloudSyncEnabled],
                    syncAssignmentRemindersEnabled: Defaults[.syncAssignmentReminders],
                    syncLiveActivityEnabled: Defaults[.syncLiveActivity],
                    isPushPending: { Defaults[.notificationSettingsPushPending] },
                    isCurrent: isCurrent
                )
                switch outcome {
                case .settled:
                    onSettled?()
                case .deferredToPendingPush:
                    // Make sure the edit that won actually goes out.
                    self.retryUnacknowledgedNotificationSettings()
                case .skipped, .abandoned:
                    break
                }
            } catch {
                AppLogger.sync.error(
                    "reconcileNotificationSettings failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    // MARK: - Debounced push trigger

    /// Debounces bursts of `liveActivityPreferencesDidChange` (e.g. a
    /// slider drag posts many in a row) into a single push, reusing
    /// `scheduleLiveActivityRefresh`'s 250 ms convention
    /// (`AppState+LiveActivity.swift`). Kept as its own timer rather than
    /// folded into that function: `scheduleLiveActivityRefresh` also runs
    /// off `dataDidUpdate` and `courseSkipStateDidChange`, neither of which
    /// is a preference change this document cares about — piggy-backing on
    /// it would fire a settings PUT on every data sync.
    ///
    /// The pending marker is set here, before the debounce rather than
    /// after it, so the window the debounce itself opens is covered: the
    /// preference is already durable in `Defaults` (the store's `didSet`
    /// wrote it before posting), and if the app is suspended or killed
    /// inside those 250 ms the marker survives and the next full sync
    /// repairs the cloud copy.
    func scheduleNotificationSettingsPush() {
        Defaults[.notificationSettingsPushPending] = true
        NotificationSettingsPushQueue.pendingDebounce?.cancel()
        NotificationSettingsPushQueue.pendingDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.enqueueNotificationSettingsPush()
        }
    }

    /// Runs one push, chained behind any push already in flight.
    ///
    /// Chained rather than fired independently, for the same reason
    /// `enqueueHolidayUpload` is (`AppState+PushServer.swift`): a push is a
    /// read-modify-write pair, and `SettingsDocumentClient` is a reentrant
    /// `actor`, so two overlapping pushes can both read revision *N* and
    /// both PUT `base_revision: N` — the loser burns its single retry on a
    /// conflict it created itself. Chaining also means the debounce's
    /// `cancel()` can only ever land on a sleeping task, never inside an
    /// in-flight PUT, and each link reads `liveActivityPreferences` at the
    /// moment it runs, so the value that gets sent is the current one
    /// rather than the one that was current when it was queued.
    ///
    /// Delegates the actual chaining/generation-guard to
    /// `NotificationSettingsPushQueue.enqueue(_:)` so that logic can be
    /// driven directly from a test without constructing an `AppState`.
    func enqueueNotificationSettingsPush() {
        NotificationSettingsPushQueue.enqueue { [weak self] in
            await self?.pushNotificationSettings()
        }
    }

    /// Re-sends preferences whose last push never landed — a dropped
    /// debounce, an expired session, being offline, a 5xx, or a conflict
    /// that outlived its one retry.
    ///
    /// Called from `syncOverridesFromBackend`, right where
    /// `retryUnacknowledgedHolidayOverrides()` is, because that is the
    /// app's own "we have a network and a session again" moment. Also
    /// covers the case where the preference was edited while cloud sync was
    /// off: the marker was set then, nothing was sent, and the first full
    /// sync after the user turns sync back on carries it up.
    func retryUnacknowledgedNotificationSettings() {
        guard Defaults[.cloudSyncEnabled] else { return }
        guard Defaults[.notificationSettingsPushPending] else { return }
        enqueueNotificationSettingsPush()
    }

    /// Abandon any queued or in-flight notification-settings push and clear
    /// the pending marker. Called at logout, right alongside
    /// `cancelHolidayUploads()` (`AppState+Account.swift`): the queue and
    /// the marker hold the departing account's preferences, and the session
    /// they would travel on now belongs to whoever signs in next.
    func cancelNotificationSettingsPushes() {
        NotificationSettingsPushQueue.cancelAll()
        Defaults[.notificationSettingsPushPending] = false
    }
    #endif // os(iOS)
}

/// Holds the debounce timer for `scheduleNotificationSettingsPush()` and
/// the serialized chain every read and write of the document runs on —
/// pushes and `reconcileNotificationSettings()` alike — plus the
/// generation guard that keeps both from outliving a logout.
///
/// Stored properties on `AppState` would be the obvious home, but this is
/// an extension and Swift does not allow them there — same constraint
/// `HolidayUploadQueue` documents in `AppState+PushServer.swift`. Static is
/// fine regardless: there is a single `AppState` per process.
///
/// Unlike `HolidayUploadQueue`, not `private`: `enqueue(_:)` and
/// `cancelAll()` take a plain closure and touch nothing `AppState`-shaped,
/// so `NotificationSettingsPushQueueTests` can drive the generation guard
/// — the actual cross-account hazard — directly. Nothing in this test
/// target constructs a full `AppState` (see `NotificationSettingsSync`'s
/// own doc comment above).
@MainActor
enum NotificationSettingsPushQueue {
    /// The sleeping debounce task. Cancelled and replaced by each new
    /// change; never holds a network call.
    static var pendingDebounce: Task<Void, Never>?
    /// The most recently queued link, push or reconcile. Each new link
    /// awaits this one before starting, so no two ever overlap. Never
    /// cancelled except by `cancelAll()`.
    static var tail: Task<Void, Never>?
    /// Bumped by `cancelAll()`. A push queued before the bump bails instead
    /// of sending the departing account's preferences over whoever signs in
    /// next. Mirrors `HolidayUploadQueue.generation`
    /// (`AppState+PushServer.swift`).
    static var generation = 0

    /// Chains `work` behind whatever push is already queued, and only runs
    /// it if `cancelAll()` has not bumped the generation since it was
    /// queued. Mirrors `enqueueHolidayUpload`'s capture-and-compare
    /// (`AppState+PushServer.swift`).
    @discardableResult
    static func enqueue(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let queuedGeneration = generation
        let task = Task { @MainActor in
            _ = await previous?.value
            // A logout between queueing and running belongs to the
            // departing account; running now would send its preferences
            // over whoever signed in since.
            guard queuedGeneration == generation else { return }
            await work()
        }
        tail = task
        return task
    }

    /// Queues one read-before-write of the document
    /// (`AppState.reconcileNotificationSettings()`) as a link on the same
    /// chain, so it cannot interleave with a push's read-modify-write, and
    /// a logout between queueing and running drops it like any other link.
    ///
    /// `reconcile` is handed `isCurrent`, which turns false once a logout
    /// bumps the generation. The guard in `enqueue(_:)` only covers the
    /// wait before a link starts, and a reconcile makes round trips after
    /// that: it checks `isCurrent` after each one, so the departing
    /// account's document is never applied and nothing is written over
    /// the next account's.
    @discardableResult
    static func enqueueReconcile(
        _ reconcile: @escaping @MainActor (_ isCurrent: @escaping @MainActor () -> Bool) async -> Void
    ) -> Task<Void, Never> {
        let queuedGeneration = generation
        return enqueue {
            await reconcile { queuedGeneration == generation }
        }
    }

    /// Abandons the sleeping debounce (if any) and the queued/in-flight
    /// chain, and bumps the generation so a link already past this point
    /// but not yet past its own guard still bails. Called from
    /// `AppState.cancelNotificationSettingsPushes()`.
    static func cancelAll() {
        generation += 1
        pendingDebounce?.cancel()
        pendingDebounce = nil
        tail?.cancel()
        tail = nil
    }
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

    enum SyncError: Error, Equatable, Sendable {
        /// The retried write also ended in conflict: adopt the server's
        /// version and retry once, but never loop forever.
        case conflictNotResolved
        /// A section this app owns did not encode to a JSON object. Cannot
        /// happen for the two `Codable` structs involved; thrown rather
        /// than defaulted so a future refactor that breaks it is loud
        /// instead of quietly writing an empty section over the server's.
        case sectionEncodingFailed
    }

    /// Local preference snapshot, decoupled from `LiveActivityPreferencesStore`
    /// so tests can construct one directly instead of standing up a real
    /// store (which reads/writes `Defaults` / `UserDefaults`).
    ///
    /// Field mapping is fixed by the table below — do not add or infer
    /// fields beyond these seven:
    ///
    /// | local                             | document field                               |
    /// |------------------------------------|-----------------------------------------------|
    /// | `isAssignmentReminderEnabled`       | `assignments.enabled`                          |
    /// | `assignmentReminderOffsets`         | `assignments.reminder_offsets_hours` + `…_minutes` |
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

        /// `AssignmentReminderOffset` → `assignments.reminder_offsets_minutes`,
        /// the lossless mirror: **every** selected offset, sub-hour ones
        /// included. Every `AssignmentReminderOffset` case is a whole number
        /// of minutes, so nothing rounds. Descending, like the hours array.
        var reminderOffsetsMinutes: [Int] {
            assignmentReminderOffsets
                .map { Int(($0.timeInterval / 60).rounded()) }
                .sorted(by: >)
        }

        /// The `assignments` section to write, given what the server
        /// currently holds at `existing`.
        ///
        /// `reminder_offsets_minutes` is this device's complete selection
        /// **plus** every minute value already in the document that no
        /// `AssignmentReminderOffset` in this build represents. Without
        /// that, a value only a different client's enum understands — a
        /// newer build's, another platform's, or this one's after the enum
        /// changes — is deleted the moment this device edits any offset and
        /// pushes: this app writes that key outright, so `merging(_:into:)`'s
        /// "leave keys you don't mention alone" cannot protect it. Android
        /// folds the same values back in
        /// (`push/NotificationSettingsSync.kt`'s `documentUpdates`).
        ///
        /// Deselection still works: a value this build *does* have a case
        /// for and the user has turned off is not foreign, so it is not
        /// preserved.
        ///
        /// `reminder_offsets_hours` is then derived from that merged set
        /// rather than computed separately, so the lossy mirror never drifts
        /// out of step with the complete one — including for a preserved
        /// value that happens to be a whole number of hours. Whole hours
        /// only, because that field has always meant whole hours to every
        /// reader that predates `reminder_offsets_minutes`: the four
        /// sub-hour cases (`min30`/`min15`/`min10`/`min5`) would collide on
        /// truncation — all four → `0` — so they are left out of it and
        /// carried losslessly in the minutes array instead. Both arrays are
        /// descending, for a deterministic, readable document (`Set`
        /// iteration order is not stable).
        ///
        /// A foreign value living only in a legacy `reminder_offsets_hours`
        /// entry, with no `reminder_offsets_minutes` beside it, is not
        /// separately preserved: every writer that knows the minutes field
        /// mirrors into it, so that shape can only come from a client older
        /// than this whole feature, and the hours field has always been the
        /// lossy one by design.
        func assignmentsSection(
            preservingForeignMinutesFrom existing: [String: Any]
        ) -> NotificationSettingsDocument.Assignments {
            let foreign = NotificationSettingsSync.foreignMinutes(in: existing)
            let minutes = Set(reminderOffsetsMinutes + foreign).sorted(by: >)
            return .init(
                enabled: isAssignmentReminderEnabled,
                reminderOffsetsHours: minutes.filter { $0 % 60 == 0 }.map { $0 / 60 },
                reminderOffsetsMinutes: minutes
            )
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

        /// The keys this app owns, as JSON objects ready to splice over
        /// whatever the server currently holds. Each section is included
        /// only when its device switch is on; a section left out here is
        /// left exactly as the server currently holds it by
        /// `merging(_:into:)` rather than overwritten with a local value
        /// the device is not supposed to be syncing.
        ///
        /// `existing` is what the server currently holds — the same object
        /// the result is about to be merged over. The `assignments` section
        /// depends on it (see `assignmentsSection(preservingForeignMinutesFrom:)`),
        /// so this must be recomputed against the document that is actually
        /// being written to, including after a 409 rebase adopts a different
        /// one.
        func documentUpdates(
            existing: [String: Any],
            includeAssignments: Bool = true,
            includeLiveActivity: Bool = true
        ) throws -> [String: Any] {
            var updates: [String: Any] = [:]
            if includeAssignments {
                updates["assignments"] = try NotificationSettingsSync.jsonObject(
                    assignmentsSection(preservingForeignMinutesFrom: existing)
                )
            }
            if includeLiveActivity {
                updates["live_activity"] = try NotificationSettingsSync.jsonObject(liveActivitySection)
            }
            return updates
        }
    }

    // MARK: - Forward-compatible merge

    /// Splices `updates` over `existing`, key by key, and returns the
    /// result. Any key `updates` does not mention survives untouched — at
    /// the top level (a whole section a newer client or Android added) and,
    /// because the merge recurses into nested objects, inside the sections
    /// this app *does* own (a field added to `live_activity` by a build
    /// that knows about it).
    ///
    /// Chosen over a typed struct carrying an unknown-keys bag for two
    /// reasons. The client already hands the document over as opaque
    /// `Data`, so the raw object is in hand at the exact moment it is
    /// needed and costs nothing extra. And a bag would have to be threaded
    /// through hand-written `init(from:)`/`encode(to:)` on
    /// `NotificationSettingsDocument` *and* on each nested section —
    /// unknown keys appear inside sections, not only beside them, so a
    /// top-level-only bag would still erase them — plus a `Sendable`,
    /// `Equatable` `AnyCodable` box to hold the values. That is a lot of
    /// machinery for something six lines of dictionary merge do exactly.
    ///
    /// Arrays are replaced wholesale, not merged: every array in this
    /// document is a complete set of user choices, and unioning them would
    /// make a removal impossible to express.
    static func merging(_ updates: [String: Any], into existing: [String: Any]) -> [String: Any] {
        var merged = existing
        for (key, value) in updates {
            if let update = value as? [String: Any],
               let current = merged[key] as? [String: Any] {
                merged[key] = merging(update, into: current)
            } else {
                merged[key] = value
            }
        }
        return merged
    }

    /// Minute values in `existing`'s `assignments.reminder_offsets_minutes`
    /// that no `AssignmentReminderOffset` in this build represents.
    ///
    /// Read through the document type's own decoder rather than by casting
    /// the raw array, so "a readable minute value" means exactly the same
    /// thing on the write path as on the read path — one element rule, in
    /// one place.
    static func foreignMinutes(in existing: [String: Any]) -> [Int] {
        let section: NotificationSettingsDocument.Assignments? =
            decodedSection(existing[OwnedSection.assignments.rawValue])
        return (section?.reminderOffsetsMinutes ?? [])
            .filter { offset(forMinutes: $0) == nil }
    }

    private static func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SyncError.sectionEncodingFailed
        }
        return object
    }

    // MARK: - Push

    /// Read-modify-write cycle for `assignments` + `live_activity`.
    /// Everything else in the document travels back exactly as read (see
    /// ``merging(_:into:)``). On a 409, adopts the server's document and
    /// its revision, then retries exactly once — never loops.
    ///
    /// `syncAssignmentRemindersEnabled` / `syncLiveActivityEnabled` gate
    /// their sections independently: a section whose switch is off is
    /// omitted from `updates`, so `merging(_:into:)` leaves the server's
    /// current value for it untouched rather than overwriting it with a
    /// local value the device is not supposed to be syncing. When both are
    /// off there is nothing to write, so this returns `false` without
    /// reading or writing anything — same as `cloudSyncEnabled == false`.
    ///
    /// Returns `true` only when a write actually landed on the server;
    /// `false` when nothing was attempted (cloud sync off, or both section
    /// switches off). The caller uses that to decide whether the pending
    /// marker can be cleared — a "didn't run" must not read as "succeeded".
    ///
    /// Deliberately tolerant of whatever the server currently holds: a
    /// document that is missing sections, or is not even a JSON object, is
    /// merged over rather than decoded. Aborting on an unparseable document
    /// would wedge this device's push permanently — every attempt throwing
    /// with only a log line — the first time another client wrote a shape
    /// this build doesn't model.
    @discardableResult
    static func push(
        local: LocalPreferences,
        client: SettingsDocumentClient,
        cloudSyncEnabled: Bool,
        syncAssignmentRemindersEnabled: Bool = true,
        syncLiveActivityEnabled: Bool = true
    ) async throws -> Bool {
        guard cloudSyncEnabled else { return false }
        // Neither section may sync — there is nothing to read or write.
        // Mirrors the guard above: "didn't run" must report `false`, never
        // `true`.
        guard syncAssignmentRemindersEnabled || syncLiveActivityEnabled else { return false }

        var existing: [String: Any] = [:]
        var baseRevision: Int?

        if let (data, revision) = try await client.read(namespace: namespace) {
            existing = Self.object(from: data)
            baseRevision = revision
        }

        var attempt = 0
        while true {
            // Rebuilt every iteration, not once before the loop: the
            // `assignments` section preserves offsets the *current*
            // document holds, and after a 409 that is the winner's
            // document, not the one this call started from.
            let updates = try local.documentUpdates(
                existing: existing,
                includeAssignments: syncAssignmentRemindersEnabled,
                includeLiveActivity: syncLiveActivityEnabled
            )
            let merged = merging(updates, into: existing)
            // `.sortedKeys` only so the bytes on the wire are deterministic
            // for a given document; the backend stores JSONB and does not
            // care about key order.
            let body = try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
            let result = try await client.write(namespace: namespace, document: body, baseRevision: baseRevision)

            switch result {
            case .written:
                return true
            case .conflict(let serverDocument, let serverRevision):
                attempt += 1
                guard attempt <= 1 else {
                    throw SyncError.conflictNotResolved
                }
                existing = Self.object(from: serverDocument)
                baseRevision = serverRevision
            }
        }
    }

    /// A settings document as a dictionary, or empty if the server is
    /// holding something that is not a JSON object. Empty is the right
    /// degradation: the merge then writes a valid document over the
    /// garbage instead of refusing to write ever again.
    private static func object(from data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// Whether `pushNotificationSettings()` may clear
    /// `Defaults[.notificationSettingsPushPending]` after this push.
    ///
    /// Only when the write actually landed (`written`) **and** the store
    /// still matches what was sent (`current == sent`). A preference edit
    /// that arrived while the request was in flight is already queued
    /// behind it (`enqueueNotificationSettingsPush`'s chain) and must stay
    /// marked pending until *that* push lands — clearing on any success
    /// would let a kill in the next 250 ms lose the newer edit with the
    /// marker already `false`. Mirrors `enqueueHolidayUpload`'s
    /// re-read-and-compare (`AppState+PushServer.swift`), which only
    /// acknowledges a holiday toggle if the server now holds what the user
    /// still wants.
    static func canClearPendingMarker(
        written: Bool,
        sent: LocalPreferences,
        current: LocalPreferences
    ) -> Bool {
        written && current == sent
    }

    /// Whether a device switch's change (`syncAssignmentReminders` /
    /// `syncLiveActivity`) should queue an extra settings push
    /// (`AppState.scheduleNotificationSettingsPush()`) beyond the
    /// unconditional device-preferences PATCH
    /// (`AppState.pushSyncPreferences()`, which fires on every change either
    /// direction and only carries the switch itself). True only on the
    /// off→on transition: turning the switch back on ungates the section it
    /// guards in `push(...)` above, and nothing else pushes that section's
    /// now-current local value to the server until this fires. The on→off
    /// direction needs no push — the section simply goes back to being left
    /// exactly as the server holds it, which needs no write. Without it,
    /// the just-ungated section stayed stale server-side until some
    /// unrelated local edit happened to trigger a push.
    static func shouldPushOnDeviceSwitchChange(old: Bool, new: Bool) -> Bool {
        new && !old
    }

    /// Whether a `liveActivityPreferencesDidChange` post should queue a
    /// settings push. Only a local edit to a field the document carries
    /// does: a remote-origin post brings values that just came from the
    /// document, and a device-only one (`isLiveActivityEnabled`) changed
    /// nothing in it.
    static func changeNeedsDocumentPush(_ userInfo: [AnyHashable: Any]?) -> Bool {
        let isRemoteOrigin = userInfo?[AppConstants.liveActivityPreferencesRemoteOriginKey] as? Bool == true
        let isDeviceOnly = userInfo?[AppConstants.liveActivityPreferencesDeviceOnlyKey] as? Bool == true
        return !isRemoteOrigin && !isDeviceOnly
    }

    // MARK: - Read before write

    /// The two sections of the document this app owns, by key.
    enum OwnedSection: String, CaseIterable, Sendable {
        case assignments
        case liveActivity = "live_activity"
    }

    /// What one ``reconcile(store:client:cloudSyncEnabled:syncAssignmentRemindersEnabled:syncLiveActivityEnabled:isPushPending:isCurrent:)``
    /// run did.
    enum ReconcileOutcome: Equatable, Sendable {
        /// Nothing to do — cloud sync is off, or neither section syncs on
        /// this device. No request was made.
        case skipped
        /// A local edit had not reached the server yet. It wins: nothing
        /// was adopted or written, and the caller runs its push instead.
        case deferredToPendingPush
        /// A logout happened mid-way. Nothing more was adopted or written.
        case abandoned
        /// The document was read and every synced section settled: the
        /// ones the server had were adopted, the ones it lacked seeded.
        case settled(adopted: Set<OwnedSection>, seeded: Set<OwnedSection>)
    }

    /// Settles this device's synced sections against the server's
    /// `notification` document, reading before it writes, section by
    /// section:
    ///
    /// - the server has the section: it is adopted onto `store` through
    ///   ``apply(_:to:)``, so a field that is absent or malformed keeps its
    ///   local value;
    /// - the document or the section is absent (a 404, or no such key):
    ///   this device's local values for that section are written, merged
    ///   over whatever else the document holds.
    ///
    /// A section syncs when its device switch is on
    /// (`syncAssignmentRemindersEnabled` / `syncLiveActivityEnabled`). One
    /// that does not is neither adopted nor written.
    ///
    /// A local edit the server has not acknowledged wins. While
    /// `isPushPending()` is true nothing is read. It is checked again after
    /// every round trip, together with the local values themselves (an
    /// edit's marker may not be set yet). Either way nothing is adopted or
    /// written, and the edit's own push carries it up.
    ///
    /// `isCurrent()` turns false once a logout has happened. It is checked
    /// after every round trip, so nothing read under the departing account
    /// is applied and nothing is written over the next account's document.
    ///
    /// A 409 on the write means another device wrote first. The winning
    /// document is settled the same way — what it now has is adopted, what
    /// it still lacks is written — and the write is retried once.
    @MainActor
    static func reconcile(
        store: LiveActivityPreferencesStore,
        client: SettingsDocumentClient,
        cloudSyncEnabled: Bool,
        syncAssignmentRemindersEnabled: Bool,
        syncLiveActivityEnabled: Bool,
        isPushPending: () -> Bool,
        isCurrent: () -> Bool = { true }
    ) async throws -> ReconcileOutcome {
        var synced: Set<OwnedSection> = []
        if syncAssignmentRemindersEnabled { synced.insert(.assignments) }
        if syncLiveActivityEnabled { synced.insert(.liveActivity) }
        guard cloudSyncEnabled, !synced.isEmpty else { return .skipped }
        guard !isPushPending() else { return .deferredToPendingPush }

        var expected = LocalPreferences(from: store)
        let stored = try await client.read(namespace: namespace)
        var existing = stored.map { Self.object(from: $0.document) } ?? [:]
        var baseRevision = stored?.revision
        var adopted: Set<OwnedSection> = []
        var attempt = 0

        while true {
            guard isCurrent() else { return .abandoned }
            guard !isPushPending(), LocalPreferences(from: store) == expected else {
                return .deferredToPendingPush
            }

            // Present means the document holds the section as an object.
            // Anything else at that key — `null`, a number — carries no
            // settings to adopt, so it is written over like a missing key.
            let present = synced.filter { existing[$0.rawValue] is [String: Any] }
            if !present.isEmpty {
                apply(Self.document(from: existing, sections: present), to: store)
                adopted.formUnion(present)
                expected = LocalPreferences(from: store)
            }

            let missing = synced.subtracting(present)
            guard !missing.isEmpty else {
                return .settled(adopted: adopted, seeded: [])
            }
            let updates = try expected.documentUpdates(
                existing: existing,
                includeAssignments: missing.contains(.assignments),
                includeLiveActivity: missing.contains(.liveActivity)
            )
            let body = try JSONSerialization.data(
                withJSONObject: merging(updates, into: existing),
                options: [.sortedKeys]
            )
            switch try await client.write(namespace: namespace, document: body, baseRevision: baseRevision) {
            case .written:
                return .settled(adopted: adopted, seeded: missing)
            case .conflict(let serverDocument, let serverRevision):
                attempt += 1
                guard attempt <= 1 else { throw SyncError.conflictNotResolved }
                existing = Self.object(from: serverDocument)
                baseRevision = serverRevision
            }
        }
    }

    /// The typed view of `sections`, each decoded on its own so one that
    /// cannot be read does not take the other with it. A section that fails
    /// to decode at all reads as absent, and every field in it then keeps
    /// its local value in ``apply(_:to:)``.
    private static func document(
        from object: [String: Any],
        sections: Set<OwnedSection>
    ) -> NotificationSettingsDocument {
        var document = NotificationSettingsDocument()
        if sections.contains(.assignments) {
            document.assignments = decodedSection(object[OwnedSection.assignments.rawValue])
        }
        if sections.contains(.liveActivity) {
            document.liveActivity = decodedSection(object[OwnedSection.liveActivity.rawValue])
        }
        return document
    }

    private static func decodedSection<T: Decodable>(_ value: Any?) -> T? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value)
        else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Applying what was read

    /// Document offsets → the local `Set<AssignmentReminderOffset>` to
    /// store. **Never returns less than the caller can justify losing.**
    ///
    /// - `reminder_offsets_minutes` present: authoritative and complete,
    ///   including the sub-hour offsets. An entry matching no case in this
    ///   build (an offset a newer client added) is skipped rather than
    ///   failing the pull — the same forward-compatibility stance the
    ///   document type takes. An empty array is a real answer: the user
    ///   turned everything off, and that must sync.
    /// - only `reminder_offsets_hours`: written by a build, or a platform,
    ///   that cannot express sub-hour offsets in it. The whole-hour offsets
    ///   are taken from the document; the device's own sub-hour selections
    ///   are **kept**, because a field that structurally cannot carry them
    ///   is not evidence the user turned them off. This is the case that
    ///   used to silently delete `.min30` — which ships in
    ///   `LiveActivityPreferencesStore.defaultOffsets`, so it hit a default
    ///   install on the first pull.
    /// - neither: the document says nothing about offsets, so nothing
    ///   changes.
    static func resolveOffsets(
        documentMinutes: [Int]?,
        documentHours: [Int]?,
        currentLocal: Set<AssignmentReminderOffset>
    ) -> Set<AssignmentReminderOffset> {
        if let documentMinutes {
            return Set(documentMinutes.compactMap(offset(forMinutes:)))
        }
        guard let documentHours else { return currentLocal }
        let fromDocument = Set(documentHours.compactMap { hours -> AssignmentReminderOffset? in
            // `hours` comes straight off the server's document, which the
            // route does not validate (`SettingsPut.document: dict`). A
            // value large enough that `hours * 60` overflows `Int` used to
            // be an arithmetic trap — a crash, not a decode error. It now
            // just fails to match any case, the same degradation an
            // out-of-range value already gets below.
            let (minutes, overflowed) = hours.multipliedReportingOverflow(by: 60)
            return overflowed ? nil : offset(forMinutes: minutes)
        })
        let localSubHour = currentLocal.filter { $0.timeInterval < 3600 }
        return fromDocument.union(localSubHour)
    }

    private static func offset(forMinutes minutes: Int) -> AssignmentReminderOffset? {
        AssignmentReminderOffset.allCases.first { Int($0.timeInterval / 60) == minutes }
    }

    /// Reverse of `LocalPreferences` above: applies the document onto the
    /// store. Every one of the seven mapped fields falls back to the
    /// store's current value when the document does not carry it, so a
    /// document written by a client that knows about fewer fields than this
    /// one narrows what a pull changes — it never resets anything to a
    /// guessed default.
    @MainActor
    static func apply(_ document: NotificationSettingsDocument, to store: LiveActivityPreferencesStore) {
        let assignments = document.assignments
        let liveActivity = document.liveActivity
        let classLeadSeconds = liveActivity?.classPreparingLeadSeconds
        let assignmentLeadSeconds = liveActivity?.assignmentLeadSeconds
        store.applyFromNotificationSettingsDocument(
            isAssignmentReminderEnabled: assignments?.enabled ?? store.isAssignmentReminderEnabled,
            assignmentReminderOffsets: resolveOffsets(
                documentMinutes: assignments?.reminderOffsetsMinutes,
                documentHours: assignments?.reminderOffsetsHours,
                currentLocal: store.assignmentReminderOffsets
            ),
            showClassPreparingScenario: liveActivity?.showClassPreparing ?? store.showClassPreparingScenario,
            showInClassScenario: liveActivity?.showInClass ?? store.showInClassScenario,
            showAssignmentScenario: liveActivity?.showAssignment ?? store.showAssignmentScenario,
            classPreparingLeadTime: classLeadSeconds.map { TimeInterval($0) }
                ?? store.classPreparingLeadTime,
            assignmentLiveActivityLeadTime: assignmentLeadSeconds.map { TimeInterval($0) }
                ?? store.assignmentLiveActivityLeadTime
        )
    }
}
