import Foundation
import Defaults
import os

nonisolated enum NotificationSettingsSync {
    static let namespace = "notification"

    enum SyncError: Error, Equatable, Sendable {
        case conflictNotResolved
        case sectionEncodingFailed
    }

    typealias LocalPreferences = NotificationSettingsLocalPreferences

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

    /// What a push compares the device's values with; nil sends every field. Only a push that
    /// NotificationSettingsSyncedSeedMigration found pending gets nil: its edit is not on the
    /// server yet, so compared with the device's own values it would send nothing and the next
    /// reconcile would revert it. A signed-in device otherwise has a copy; without one nothing
    /// counts as changed.
    @MainActor
    static func pushBase(local: LocalPreferences) -> LocalPreferences? {
        synced ?? (Defaults[.notificationSettingsPushSendsEveryField] ? nil : local)
    }

    /// A sign-in starts the copy from the device's values, so what was edited while signed out
    /// gives way to the account's document and an edit made after the sign-in goes up.
    @MainActor
    static func accountSignedIn(local: LocalPreferences) {
        guard synced == nil, !Defaults[.notificationSettingsPushSendsEveryField] else { return }
        synced = local
    }

    @MainActor
    static func sectionTurnedOn(_ section: OwnedSection, local: LocalPreferences) {
        guard let synced else { return }
        self.synced = synced.replacing(section, from: local)
    }

    /// Takes into the copy only the fields the push sent, since the copy may have changed while
    /// the request was out, for example a section switch turned back on.
    @MainActor
    static func recordPushed(_ sent: LocalPreferences, fields: [String: Any]) {
        synced = (synced ?? sent).taking(fields, from: sent)
        Defaults[.notificationSettingsPushSendsEveryField] = false
    }

    /// Takes into the copy only the sections a reconcile synced, so a section turned on while its
    /// write was out keeps the copy `sectionTurnedOn` gave it.
    @MainActor
    static func recordSynced(_ settled: LocalPreferences, sections: Set<OwnedSection>) {
        synced = sections.reduce(synced ?? settled) { $0.replacing($1, from: settled) }
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
    static func changes(
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
            NotificationSettingsReconcile.decodedSection(existing[OwnedSection.assignments.rawValue])
        return (section?.reminderOffsetsMinutes ?? [])
            .filter { NotificationSettingsReconcile.offset(forMinutes: $0) == nil }
    }

    static func classReminderOffsets(in existing: [String: Any]) -> [Int]? {
        let section: NotificationSettingsDocument.Courses? =
            NotificationSettingsReconcile.decodedSection(existing[OwnedSection.courses.rawValue])
        return section?.reminderOffsetsMinutes
    }

    static func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
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
        base: LocalPreferences?,
        client: SettingsDocumentClient,
        cloudSyncEnabled: Bool,
        syncAssignmentRemindersEnabled: Bool = true,
        syncLiveActivityEnabled: Bool = true,
        isCurrent: () -> Bool = { true },
        recordSent: ([String: Any]) -> Void = { _ in }
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
            // A write that changes nothing still moves the revision, which sends every device to
            // reconcile. The server already holds the changed fields, so they count as sent.
            if NSDictionary(dictionary: merged).isEqual(to: existing) {
                recordSent(updates)
                return isCurrent()
            }
            let body = try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
            let result = try await client.write(namespace: namespace, document: body, baseRevision: baseRevision)

            switch result {
            case .written:
                recordSent(updates)
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

    static func object(from data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    static func canClearPendingMarker(
        written: Bool,
        sent: LocalPreferences,
        current: LocalPreferences
    ) -> Bool {
        written && current == sent
    }

    static func shouldAdoptOnDeviceSwitchChange(old: Bool, new: Bool) -> Bool {
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

    enum ReconcileOutcome: Equatable, Sendable {
        case skipped
        case deferredToPendingPush
        case abandoned
        case settled(adopted: Set<OwnedSection>, seeded: Set<OwnedSection>)
    }
}
