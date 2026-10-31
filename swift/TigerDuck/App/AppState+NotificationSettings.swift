import Foundation
import Defaults
import os

extension AppState {
    #if os(iOS)

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
                // No copy stored: no field counts as changed, so the push cannot revert a newer one.
                base: NotificationSettingsSync.synced ?? local,
                client: client,
                cloudSyncEnabled: Defaults[.cloudSyncEnabled],
                syncAssignmentRemindersEnabled: Defaults[.syncAssignmentReminders],
                syncLiveActivityEnabled: Defaults[.syncLiveActivity],
                isCurrent: isCurrent
            )
            guard written, isCurrent() else { return }
            NotificationSettingsSync.synced = local
            if NotificationSettingsSync.canClearPendingMarker(
                written: written,
                sent: local,
                current: .init(from: liveActivityPreferences)
            ) {
                Defaults[.notificationSettingsPushPending] = false
            }
        } catch {
            AppLogger.sync.error(
                "pushNotificationSettings failed: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    @discardableResult
    func reconcileNotificationSettings(
        onSettled: (@MainActor () -> Void)? = nil,
        snapshot: NotificationSettingsSync.DocumentSource = .read,
        linksBeforeSnapshot: Int = 0
    ) -> Task<Void, Never> {
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
                    isCurrent: isCurrent,
                    source: NotificationSettingsPushQueue.source(snapshot, linksBeforeSnapshot: linksBeforeSnapshot),
                    recordSynced: { NotificationSettingsSync.synced = $0 }
                )
                switch outcome {
                case .settled:
                    onSettled?()
                case .deferredToPendingPush:
                    self.retryUnacknowledgedNotificationSettings()
                case .skipped, .abandoned:
                    break
                }
            } catch {
                AppLogger.sync.error(
                    "reconcileNotificationSettings failed: \(error.localizedDescription, privacy: .private)"
                )
            }
        }
    }

    func scheduleNotificationSettingsPush() {
        Defaults[.notificationSettingsPushPending] = true
        NotificationSettingsPushQueue.debounce { [weak self] in
            self?.enqueueNotificationSettingsPush()
        }
    }

    func enqueueNotificationSettingsPush() {
        NotificationSettingsPushQueue.enqueuePush { [weak self] isCurrent in
            await self?.pushNotificationSettings(isCurrent: isCurrent)
        }
    }

    func retryUnacknowledgedNotificationSettings() {
        guard Defaults[.cloudSyncEnabled] else { return }
        guard Defaults[.notificationSettingsPushPending] else { return }
        enqueueNotificationSettingsPush()
    }

    func cancelNotificationSettingsPushes() {
        NotificationSettingsPushQueue.cancelAll()
        Defaults[.notificationSettingsPushPending] = false
        Defaults[.notificationSettingsSyncedPreferences] = nil
    }
    #endif
}

@MainActor
enum NotificationSettingsPushQueue {
    static var pendingDebounce: Task<Void, Never>?
    static var tail: Task<Void, Never>?
    static var generation = 0
    private(set) static var finishedLinks = 0

    static func source(
        _ snapshot: NotificationSettingsSync.DocumentSource,
        linksBeforeSnapshot: Int
    ) -> NotificationSettingsSync.DocumentSource {
        finishedLinks == linksBeforeSnapshot ? snapshot : .read
    }

    static func debounce(
        _ work: @escaping @MainActor () -> Void,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        pendingDebounce?.cancel()
        pendingDebounce = Task { @MainActor in
            await sleep(.milliseconds(250))
            guard !Task.isCancelled else { return }
            work()
        }
    }

    @discardableResult
    static func enqueue(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let queuedGeneration = generation
        let task = Task { @MainActor in
            _ = await previous?.value
            guard queuedGeneration == generation else { return }
            await work()
            finishedLinks &+= 1
        }
        tail = task
        return task
    }

    @discardableResult
    static func enqueueReconcile(
        _ reconcile: @escaping @MainActor (_ isCurrent: @escaping @MainActor () -> Bool) async -> Void
    ) -> Task<Void, Never> {
        enqueueGuarded(reconcile)
    }

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

    static func cancelAll() {
        generation += 1
        pendingDebounce?.cancel()
        pendingDebounce = nil
        tail?.cancel()
        tail = nil
    }
}

nonisolated enum NotificationSettingsSync {
    static let namespace = "notification"

    enum SyncError: Error, Equatable, Sendable {
        case conflictNotResolved
        case sectionEncodingFailed
    }

    struct LocalPreferences: Equatable, Sendable, Codable {
        var isAssignmentReminderEnabled: Bool
        var assignmentReminderOffsets: Set<AssignmentReminderOffset>
        var showClassPreparingScenario: Bool
        var showInClassScenario: Bool
        var showAssignmentScenario: Bool
        var classPreparingLeadTime: TimeInterval
        var assignmentLiveActivityLeadTime: TimeInterval
        var isClassReminderEnabled: Bool
        var classReminderLeadMinutes: Int
        var hasPickedClassReminderLead: Bool

        init(
            isAssignmentReminderEnabled: Bool,
            assignmentReminderOffsets: Set<AssignmentReminderOffset>,
            showClassPreparingScenario: Bool,
            showInClassScenario: Bool,
            showAssignmentScenario: Bool,
            classPreparingLeadTime: TimeInterval,
            assignmentLiveActivityLeadTime: TimeInterval,
            isClassReminderEnabled: Bool,
            classReminderLeadMinutes: Int,
            hasPickedClassReminderLead: Bool
        ) {
            self.isAssignmentReminderEnabled = isAssignmentReminderEnabled
            self.assignmentReminderOffsets = assignmentReminderOffsets
            self.showClassPreparingScenario = showClassPreparingScenario
            self.showInClassScenario = showInClassScenario
            self.showAssignmentScenario = showAssignmentScenario
            self.classPreparingLeadTime = classPreparingLeadTime
            self.assignmentLiveActivityLeadTime = assignmentLiveActivityLeadTime
            self.isClassReminderEnabled = isClassReminderEnabled
            self.classReminderLeadMinutes = classReminderLeadMinutes
            self.hasPickedClassReminderLead = hasPickedClassReminderLead
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
                assignmentLiveActivityLeadTime: store.assignmentLiveActivityLeadTime,
                isClassReminderEnabled: store.isClassReminderEnabled,
                classReminderLeadMinutes: store.classReminderLeadMinutes,
                hasPickedClassReminderLead: store.hasPickedClassReminderLead
            )
        }

        var reminderOffsetsMinutes: [Int] {
            assignmentReminderOffsets
                .map { Int(($0.timeInterval / 60).rounded()) }
                .sorted(by: >)
        }

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

        func coursesSection(
            preservingOffsetsIn existing: [String: Any]
        ) -> NotificationSettingsDocument.Courses {
            let writesLead = hasPickedClassReminderLead
                || NotificationSettingsSync.classReminderOffsets(in: existing) == nil
            return .init(
                enabled: isClassReminderEnabled,
                reminderOffsetsMinutes: writesLead ? [classReminderLeadMinutes] : nil
            )
        }

        func documentUpdates(
            existing: [String: Any],
            since synced: LocalPreferences? = nil,
            includeAssignments: Bool = true,
            includeLiveActivity: Bool = true,
            includeCourses: Bool = true
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
            if includeCourses {
                updates["courses"] = try NotificationSettingsSync.jsonObject(
                    coursesSection(preservingOffsetsIn: existing)
                )
            }
            guard let synced else { return updates }
            let before = try synced.documentUpdates(
                existing: existing,
                includeAssignments: includeAssignments,
                includeLiveActivity: includeLiveActivity,
                includeCourses: includeCourses
            )
            return NotificationSettingsSync.changes(in: updates, since: before, over: existing)
        }
    }

    @MainActor
    static var synced: LocalPreferences? {
        get {
            Defaults[.notificationSettingsSyncedPreferences]
                .flatMap { try? JSONDecoder().decode(LocalPreferences.self, from: $0) }
        }
        set {
            Defaults[.notificationSettingsSyncedPreferences] = newValue.flatMap { try? JSONEncoder().encode($0) }
        }
    }

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

    /// The fields of `updates` that differ from `synced` or that `existing` lacks, so a push keeps
    /// every other field as the server holds it. A section `existing` lacks goes whole, and the
    /// two offset lists, one mirroring the other, count as one field.
    private static func changes(
        in updates: [String: Any],
        since synced: [String: Any],
        over existing: [String: Any]
    ) -> [String: Any] {
        let offsets: Set = ["reminder_offsets_minutes", "reminder_offsets_hours"]
        return updates.reduce(into: [:]) { changed, entry in
            guard let fields = entry.value as? [String: Any],
                  let server = existing[entry.key] as? [String: Any]
            else {
                changed[entry.key] = entry.value
                return
            }
            let before = synced[entry.key] as? [String: Any] ?? [:]
            changed[entry.key] = fields.filter { key, _ in
                let field: Set = offsets.contains(key) ? offsets : [key]
                return field.allSatisfy { server[$0] == nil }
                    || field.contains { (fields[$0] as? NSObject) != (before[$0] as? NSObject) }
            }
        }
    }

    static func foreignMinutes(in existing: [String: Any]) -> [Int] {
        let section: NotificationSettingsDocument.Assignments? =
            decodedSection(existing[OwnedSection.assignments.rawValue])
        return (section?.reminderOffsetsMinutes ?? [])
            .filter { offset(forMinutes: $0) == nil }
    }

    static func classReminderOffsets(in existing: [String: Any]) -> [Int]? {
        let section: NotificationSettingsDocument.Courses? =
            decodedSection(existing[OwnedSection.courses.rawValue])
        return section?.reminderOffsetsMinutes
    }

    private static func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SyncError.sectionEncodingFailed
        }
        return object
    }

    /// Writes the fields `local` changed since `base` over the server's document; see
    /// docs/decisions/0002-notification-settings-json-merge.md. Reports whether the write landed
    /// while the account that started it is still signed in.
    @MainActor
    @discardableResult
    static func push(
        local: LocalPreferences,
        base: LocalPreferences,
        client: SettingsDocumentClient,
        cloudSyncEnabled: Bool,
        syncAssignmentRemindersEnabled: Bool = true,
        syncLiveActivityEnabled: Bool = true,
        isCurrent: () -> Bool = { true }
    ) async throws -> Bool {
        guard cloudSyncEnabled else { return false }

        var existing: [String: Any] = [:]
        var baseRevision: Int?

        if let (data, revision) = try await client.read(namespace: namespace) {
            existing = Self.object(from: data)
            baseRevision = revision
        }

        var attempt = 0
        while true {
            guard isCurrent() else { return false }
            let updates = try local.documentUpdates(
                existing: existing,
                since: base,
                includeAssignments: syncAssignmentRemindersEnabled,
                includeLiveActivity: syncLiveActivityEnabled
            )
            let merged = merging(updates, into: existing)
            let body = try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
            let result = try await client.write(namespace: namespace, document: body, baseRevision: baseRevision)

            switch result {
            case .written:
                return isCurrent()
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

    private static func object(from data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    static func canClearPendingMarker(
        written: Bool,
        sent: LocalPreferences,
        current: LocalPreferences
    ) -> Bool {
        written && current == sent
    }

    static func shouldPushOnDeviceSwitchChange(old: Bool, new: Bool) -> Bool {
        new && !old
    }

    static func changeNeedsDocumentPush(_ userInfo: [AnyHashable: Any]?) -> Bool {
        let isRemoteOrigin = userInfo?[AppConstants.liveActivityPreferencesRemoteOriginKey] as? Bool == true
        let isDeviceOnly = userInfo?[AppConstants.liveActivityPreferencesDeviceOnlyKey] as? Bool == true
        return !isRemoteOrigin && !isDeviceOnly
    }

    enum OwnedSection: String, CaseIterable, Sendable {
        case assignments
        case liveActivity = "live_activity"
        case courses
    }

    enum DocumentSource: Sendable {
        case read
        case snapshot((document: Data, revision: Int)?)
    }

    static func documentSource(fromSnapshot json: [String: Any]) -> DocumentSource {
        guard let entries = json["settings_documents"] as? [[String: Any]] else { return .read }
        guard let entry = entries.first(where: { $0["namespace"] as? String == namespace }) else {
            return .snapshot(nil)
        }
        guard let revision = entry["revision"] as? Int,
              let object = entry["document"], JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object)
        else { return .read }
        return .snapshot((document: data, revision: revision))
    }

    enum ReconcileOutcome: Equatable, Sendable {
        case skipped
        case deferredToPendingPush
        case abandoned
        case settled(adopted: Set<OwnedSection>, seeded: Set<OwnedSection>)
    }

    @MainActor
    static func reconcile(
        store: LiveActivityPreferencesStore,
        client: SettingsDocumentClient,
        cloudSyncEnabled: Bool,
        syncAssignmentRemindersEnabled: Bool,
        syncLiveActivityEnabled: Bool,
        isPushPending: () -> Bool,
        isCurrent: () -> Bool = { true },
        source: DocumentSource = .read,
        recordSynced: (LocalPreferences) -> Void = { _ in }
    ) async throws -> ReconcileOutcome {
        var synced: Set<OwnedSection> = [.courses]
        if syncAssignmentRemindersEnabled { synced.insert(.assignments) }
        if syncLiveActivityEnabled { synced.insert(.liveActivity) }
        guard cloudSyncEnabled else { return .skipped }
        guard !isPushPending() else { return .deferredToPendingPush }

        var expected = LocalPreferences(from: store)
        let stored: (document: Data, revision: Int)?
        switch source {
        case .read: stored = try await client.read(namespace: namespace)
        case .snapshot(let document): stored = document
        }
        var existing = stored.map { Self.object(from: $0.document) } ?? [:]
        var baseRevision = stored?.revision
        var adopted: Set<OwnedSection> = []
        var attempt = 0

        while true {
            guard isCurrent() else { return .abandoned }
            guard !isPushPending(), LocalPreferences(from: store) == expected else {
                return .deferredToPendingPush
            }

            let present = synced.filter { existing[$0.rawValue] is [String: Any] }
            if !present.isEmpty {
                apply(Self.document(from: existing, sections: present), to: store)
                adopted.formUnion(present)
                expected = LocalPreferences(from: store)
            }

            let missing = synced.subtracting(present)
            guard !missing.isEmpty else {
                recordSynced(expected)
                return .settled(adopted: adopted, seeded: [])
            }
            let updates = try expected.documentUpdates(
                existing: existing,
                includeAssignments: missing.contains(.assignments),
                includeLiveActivity: missing.contains(.liveActivity),
                includeCourses: missing.contains(.courses)
            )
            let body = try JSONSerialization.data(
                withJSONObject: merging(updates, into: existing),
                options: [.sortedKeys]
            )
            switch try await client.write(namespace: namespace, document: body, baseRevision: baseRevision) {
            case .written:
                if isCurrent() { recordSynced(expected) }
                return .settled(adopted: adopted, seeded: missing)
            case .conflict(let serverDocument, let serverRevision):
                attempt += 1
                guard attempt <= 1 else { throw SyncError.conflictNotResolved }
                existing = Self.object(from: serverDocument)
                baseRevision = serverRevision
            }
        }
    }

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
        if sections.contains(.courses) {
            document.courses = decodedSection(object[OwnedSection.courses.rawValue])
        }
        return document
    }

    private static func decodedSection<T: Decodable>(_ value: Any?) -> T? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value)
        else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

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
            let (minutes, overflowed) = hours.multipliedReportingOverflow(by: 60)
            return overflowed ? nil : offset(forMinutes: minutes)
        })
        let localSubHour = currentLocal.filter { $0.timeInterval < 3600 }
        return fromDocument.union(localSubHour)
    }

    static func resolveClassReminderLead(
        documentMinutes: [Int]?,
        currentMinutes: Int,
        currentPicked: Bool
    ) -> (minutes: Int, picked: Bool) {
        guard let documentMinutes else { return (currentMinutes, currentPicked) }
        let choices = LiveActivityPreferencesStore.classReminderLeadChoices.map { Int($0.timeInterval / 60) }
        let smallest = documentMinutes.min().flatMap { choices.contains($0) ? $0 : nil }
        return (smallest ?? currentMinutes, false)
    }

    private static func offset(forMinutes minutes: Int) -> AssignmentReminderOffset? {
        AssignmentReminderOffset.allCases.first { Int($0.timeInterval / 60) == minutes }
    }

    @MainActor
    static func apply(_ document: NotificationSettingsDocument, to store: LiveActivityPreferencesStore) {
        let assignments = document.assignments
        let liveActivity = document.liveActivity
        let classLeadSeconds = liveActivity?.classPreparingLeadSeconds
        let assignmentLeadSeconds = liveActivity?.assignmentLeadSeconds
        let classReminderLead = resolveClassReminderLead(
            documentMinutes: document.courses?.reminderOffsetsMinutes,
            currentMinutes: store.classReminderLeadMinutes,
            currentPicked: store.hasPickedClassReminderLead
        )
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
                ?? store.assignmentLiveActivityLeadTime,
            isClassReminderEnabled: document.courses?.enabled ?? store.isClassReminderEnabled,
            classReminderLeadMinutes: classReminderLead.minutes,
            hasPickedClassReminderLead: classReminderLead.picked
        )
    }
}
