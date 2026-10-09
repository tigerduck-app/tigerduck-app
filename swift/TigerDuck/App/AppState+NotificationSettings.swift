// The `notification` settings document: this app owns only `assignments` and `live_activity`,
// so writes merge at the JSON level, keeping `courses` and every other key. iOS only, like
// `LiveActivityPreferencesStore`. See docs/decisions/0002-notification-settings-json-merge.md.

import Foundation
import Defaults
import os

extension AppState {
    #if os(iOS)

    // MARK: - Public entry points

    /// Pushes this device's `assignments` and `live_activity` preferences, each section only
    /// while its device switch is on (see `NotificationSettingsSync.push`). Cloud sync and a
    /// session are checked first, not inferred from a 401: a revoked or expired session also
    /// gets a 401 and needs different handling. Failures are logged, not thrown, since no
    /// caller awaits this. The pending marker stays set until a write lands with nothing
    /// changed locally since, and the next full sync retries. `isCurrent` turns false after a
    /// logout. It is checked before every write and before the marker is touched, because the
    /// marker, like the session, then belongs to whoever signed in.
    func pushNotificationSettings(isCurrent: @escaping @MainActor () -> Bool = { true }) async {
        guard Defaults[.cloudSyncEnabled] else { return }
        guard await authTokenManager.isLoggedIn, isCurrent() else { return }

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
                syncLiveActivityEnabled: Defaults[.syncLiveActivity],
                isCurrent: isCurrent
            )
            // Clear only if the store still matches what was sent. An edit made in
            // flight is queued behind this push and must stay pending until its own
            // push lands, or a kill in the next 250 ms would lose it.
            if isCurrent(), NotificationSettingsSync.canClearPendingMarker(
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

    /// The one routine that reads the `notification` document: it adopts each synced section
    /// the server has and writes only the ones it lacks (`NotificationSettingsSync.reconcile`).
    /// It runs on the push queue, so it never interleaves with a push or outlives a logout.
    /// Called after upgrade, after each successful full sync, when a notification settings
    /// screen opens, and after sign-in, which must read first: a push could write a previous
    /// account's values over the new account's document. An unacknowledged local edit wins and
    /// its push runs instead. Gated on cloud sync and a session like the push; `onSettled` runs
    /// only once the document was read and every synced section settled.
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

    /// Debounces bursts of `liveActivityPreferencesDidChange` (a slider drag posts many) into
    /// one push, with the same 250 ms as `scheduleLiveActivityRefresh`. It has its own timer
    /// because that function also runs on `dataDidUpdate` and `courseSkipStateDidChange`, and
    /// sharing it would send a settings PUT on every data sync.
    ///
    /// The pending marker is set before the debounce: the store's `didSet` already wrote the
    /// preference to `Defaults`, so if the app is suspended or killed within the 250 ms, the
    /// marker survives and the next full sync repairs the cloud copy.
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
    /// A push is a read-modify-write and `SettingsDocumentClient` is a reentrant actor: two
    /// overlapping pushes could both read revision N and PUT `base_revision: N`, and the loser
    /// would spend its one retry on a conflict it caused. Chaining also keeps the debounce's
    /// `cancel()` off an in-flight PUT, and each link reads `liveActivityPreferences` when it
    /// runs, so it sends the current value. The chain and generation guard live on
    /// `NotificationSettingsPushQueue` so a test can drive them without an `AppState`.
    func enqueueNotificationSettingsPush() {
        NotificationSettingsPushQueue.enqueuePush { [weak self] isCurrent in
            await self?.pushNotificationSettings(isCurrent: isCurrent)
        }
    }

    /// Re-sends preferences whose last push never landed: a dropped debounce, an expired
    /// session, being offline, a 5xx, or a conflict that outlived its one retry.
    ///
    /// Called from `syncOverridesFromBackend`, beside `retryUnacknowledgedHolidayOverrides()`,
    /// because that is when the app has a network and a session again. It also carries up an
    /// edit made while cloud sync was off: the marker was set then and nothing was sent, so the
    /// first full sync after the user turns cloud sync back on sends it.
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

/// The debounce timer for `scheduleNotificationSettingsPush()`, the serial chain every read
/// and write of the document runs on (pushes and `reconcileNotificationSettings()` alike), and
/// the generation guard that keeps both from outliving a logout.
///
/// Static because an extension cannot add stored properties to `AppState`, and there is one
/// `AppState` per process. Not `private`, unlike `HolidayUploadQueue`: it touches nothing on
/// `AppState`, so `NotificationSettingsPushQueueTests` can drive the generation guard, the
/// cross-account hazard, directly.
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

    /// Queues one read-before-write of the document (`AppState.reconcileNotificationSettings()`)
    /// on the same chain, so it cannot interleave with a push's read-modify-write, and a logout
    /// between queueing and running drops it like any other link.
    ///
    /// The guard in `enqueue(_:)` only covers the wait before a link starts, and a reconcile
    /// makes round trips after that. So `reconcile` gets `isCurrent`, false once a logout bumps
    /// the generation, and checks it after each round trip: the departing account's document is
    /// never applied, and nothing is written over the next account's.
    @discardableResult
    static func enqueueReconcile(
        _ reconcile: @escaping @MainActor (_ isCurrent: @escaping @MainActor () -> Bool) async -> Void
    ) -> Task<Void, Never> {
        enqueueGuarded(reconcile)
    }

    /// Queues one push (`AppState.pushNotificationSettings(isCurrent:)`)
    /// the same way. A push also reads the document before it writes it, so
    /// a logout can land between the two; it checks `isCurrent` before every
    /// write, and a document read under the departing account is never
    /// written over the next account's.
    @discardableResult
    static func enqueuePush(
        _ push: @escaping @MainActor (_ isCurrent: @escaping @MainActor () -> Bool) async -> Void
    ) -> Task<Void, Never> {
        enqueueGuarded(push)
    }

    private static func enqueueGuarded(
        _ work: @escaping @MainActor (_ isCurrent: @escaping @MainActor () -> Bool) async -> Void
    ) -> Task<Void, Never> {
        let queuedGeneration = generation
        return enqueue {
            await work { queuedGeneration == generation }
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

/// Push and pull logic for the `notification` settings document, kept out of the `AppState`
/// extension so tests can reach it without a full `AppState`, which pulls in SwiftData,
/// `AuthService` and live push registration.
///
/// `nonisolated`, like `NotificationSettingsDocument` and `SettingsWriteResult`: the type has
/// no actor affinity of its own, and members that touch the `@MainActor`
/// `LiveActivityPreferencesStore`, such as `apply`, are marked `@MainActor` one by one.
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

    /// Local preference snapshot, apart from `LiveActivityPreferencesStore` so tests can build
    /// one without a real store, which reads and writes `UserDefaults`.
    ///
    /// The field mapping is fixed: do not add or infer fields beyond these seven. Each maps to
    /// one field of the `assignments` or `live_activity` section (`assignmentsSection(...)`,
    /// `liveActivitySection`), except `assignmentReminderOffsets`, which fills both
    /// `reminder_offsets_minutes` and `reminder_offsets_hours`.
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

        /// The `assignments` section to write over `existing`, the document the server holds.
        /// `reminder_offsets_minutes` is this device's selection plus every value in `existing`
        /// that no `AssignmentReminderOffset` case represents, since this app writes the key
        /// outright and the merge cannot keep them. A known value the user deselected is removed.
        /// `reminder_offsets_hours` derives from it, holding whole hours of at least one: a
        /// sub-hour value would truncate to 0, and 0 or a negative would read to an old client as
        /// a reminder at or after the deadline. A foreign value only in the hours field is not
        /// kept. See docs/decisions/0002-notification-settings-json-merge.md.
        func assignmentsSection(
            preservingForeignMinutesFrom existing: [String: Any]
        ) -> NotificationSettingsDocument.Assignments {
            let foreign = NotificationSettingsSync.foreignMinutes(in: existing)
            let minutes = Set(reminderOffsetsMinutes + foreign).sorted(by: >)
            return .init(
                enabled: isAssignmentReminderEnabled,
                reminderOffsetsHours: minutes.filter { $0 >= 60 && $0 % 60 == 0 }.map { $0 / 60 },
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

        /// The keys this app owns, as JSON objects to splice over what the server holds. A
        /// section is included only while its device switch is on; one left out stays as the
        /// server holds it (`merging(_:into:)`), never overwritten with a local value.
        ///
        /// `existing` is the object the result is merged over, and the `assignments` section
        /// depends on it. Recompute this against the document actually being written, including
        /// after a 409 rebase adopts a different one.
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

    /// Splices `updates` over `existing` key by key, recursing into nested objects, so a key
    /// `updates` does not mention survives: a section another client added, or a field a newer
    /// build added inside a section this app owns.
    ///
    /// Arrays are replaced whole, not merged: each is a complete set of user choices, and a
    /// union could not express a removal. Chosen over a typed struct with an unknown-keys bag.
    /// See docs/decisions/0002-notification-settings-json-merge.md.
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

    /// Read-modify-write of `assignments` and `live_activity`; every other key goes back as read
    /// (``merging(_:into:)``). A 409 adopts the server's document and revision for one retry. A
    /// section whose device switch is off is left as the server holds it. Returns `true` only if
    /// a write landed, so a push that did not run cannot clear the pending marker: cloud sync
    /// off, both switches off, or a logout. `isCurrent()` turns false on a logout and is checked
    /// before every write, so the departing account's document never lands on the next one's.
    /// The server's document is merged over, not decoded: aborting on a shape this build does
    /// not model would wedge every later push.
    @MainActor
    @discardableResult
    static func push(
        local: LocalPreferences,
        client: SettingsDocumentClient,
        cloudSyncEnabled: Bool,
        syncAssignmentRemindersEnabled: Bool = true,
        syncLiveActivityEnabled: Bool = true,
        isCurrent: () -> Bool = { true }
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
            guard isCurrent() else { return false }
            // Rebuilt every iteration, not once before the loop: `assignments` preserves
            // offsets the current document holds, and after a 409 that is the winner's
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

    /// Whether `pushNotificationSettings(isCurrent:)` may clear
    /// `Defaults[.notificationSettingsPushPending]` after this push.
    ///
    /// Only when the write landed (`written`) and the store still matches what was sent
    /// (`current == sent`). An edit that arrived while the request was in flight is queued
    /// behind it and must stay pending until its own push lands; clearing on any success would
    /// let a kill in the next 250 ms lose that edit. Same rule as `enqueueHolidayUpload`.
    static func canClearPendingMarker(
        written: Bool,
        sent: LocalPreferences,
        current: LocalPreferences
    ) -> Bool {
        written && current == sent
    }

    /// Whether changing a device switch (`syncAssignmentReminders`, `syncLiveActivity`) should
    /// queue a settings push (`AppState.scheduleNotificationSettingsPush()`) on top of the
    /// device-preferences PATCH (`AppState.pushSyncPreferences()`), which fires on every change
    /// and carries only the switch.
    ///
    /// Only off to on: that ungates the section in `push(...)`, and nothing else would send its
    /// current local value until some unrelated edit. Turning a switch off needs no write: the
    /// section is then left as the server holds it.
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

    /// Settles each section whose device switch is on against the `notification` document, read
    /// first. A section the server has is adopted through ``apply(_:to:)``, and an absent or
    /// malformed field keeps its local value. A section it lacks is written from local values.
    /// An unacknowledged local edit wins, and its own push carries it: nothing is read while
    /// `isPushPending()`. After each round trip that and the local values are checked again, as
    /// an edit's marker may not be set yet, and so is `isCurrent()`: nothing from a logged-out
    /// account is applied or written. On a 409 the winner's document is settled the same way and
    /// the write is retried once.
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

    /// Maps the document's offsets to the local set, dropping only what the document justifies.
    ///
    /// - `reminder_offsets_minutes` present: authoritative, sub-hour offsets included. An entry
    ///   no case matches (a newer client's) is skipped, not fatal. An empty array means all off.
    /// - only `reminder_offsets_hours`: whole hours come from the document, and the device keeps
    ///   its sub-hour offsets, since that field cannot carry them; dropping them would delete the
    ///   default `.min30` on a fresh install's first pull.
    /// - neither: nothing changes.
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
            // `hours` comes from the server's document, which the route does not validate
            // (`SettingsPut.document: dict`). `hours * 60` could overflow and trap, so an
            // overflowing value matches no case instead, like any other out-of-range value.
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
