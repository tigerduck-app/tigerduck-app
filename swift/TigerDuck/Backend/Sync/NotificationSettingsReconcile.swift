import Foundation
import Defaults
import os

/// Reads the settings document against this device's preferences: adopts the sections the
/// server holds and seeds the ones it lacks.
nonisolated enum NotificationSettingsReconcile {
    typealias LocalPreferences = NotificationSettingsSync.LocalPreferences
    typealias OwnedSection = NotificationSettingsSync.OwnedSection
    typealias DocumentSource = NotificationSettingsSync.DocumentSource
    typealias ReconcileOutcome = NotificationSettingsSync.ReconcileOutcome

    static func documentSource(fromSnapshot json: [String: Any]) -> DocumentSource {
        guard let entries = json["settings_documents"] as? [[String: Any]] else { return .read }
        guard let entry = entries.first(where: { $0["namespace"] as? String == NotificationSettingsSync.namespace }) else {
            return .snapshot(nil)
        }
        guard let revision = entry["revision"] as? Int,
              let object = entry["document"], JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object)
        else { return .read }
        return .snapshot((document: data, revision: revision))
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
        recordSynced: (LocalPreferences, Set<OwnedSection>) -> Void = { _, _ in }
    ) async throws -> ReconcileOutcome {
        var synced: Set<OwnedSection> = [.courses]
        if syncAssignmentRemindersEnabled { synced.insert(.assignments) }
        if syncLiveActivityEnabled { synced.insert(.liveActivity) }
        guard cloudSyncEnabled else { return .skipped }
        guard !isPushPending() else { return .deferredToPendingPush }

        var expected = LocalPreferences(from: store)
        let stored: (document: Data, revision: Int)?
        switch source {
        case .read: stored = try await client.read(namespace: NotificationSettingsSync.namespace)
        case .snapshot(let document): stored = document
        }
        var existing = stored.map { NotificationSettingsSync.object(from: $0.document) } ?? [:]
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
                recordSynced(expected, synced)
                return .settled(adopted: adopted, seeded: [])
            }
            let updates = try expected.documentUpdates(
                existing: existing,
                includeAssignments: missing.contains(.assignments),
                includeLiveActivity: missing.contains(.liveActivity),
                includeCourses: missing.contains(.courses)
            )
            let body = try JSONSerialization.data(
                withJSONObject: NotificationSettingsSync.merging(updates, into: existing),
                options: [.sortedKeys]
            )
            switch try await client.write(namespace: NotificationSettingsSync.namespace, document: body, baseRevision: baseRevision) {
            case .written:
                if isCurrent() { recordSynced(expected, synced) }
                return .settled(adopted: adopted, seeded: missing)
            case .conflict(let serverDocument, let serverRevision):
                attempt += 1
                guard attempt <= 1 else { throw NotificationSettingsSync.SyncError.conflictNotResolved }
                existing = NotificationSettingsSync.object(from: serverDocument)
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

    static func decodedSection<T: Decodable>(_ value: Any?) -> T? {
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

    static func offset(forMinutes minutes: Int) -> AssignmentReminderOffset? {
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
