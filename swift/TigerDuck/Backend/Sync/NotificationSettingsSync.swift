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

    enum PushBase: Equatable, Sendable {
        case everyField
        case since(LocalPreferences)
    }

    enum PushResult: Equatable, Sendable {
        case landed
        case skipped
    }

    static let mirroredOffsetKeys: Set<String> = ["reminder_offsets_minutes", "reminder_offsets_hours"]

    @MainActor
    static var lastSyncedPreferences: LocalPreferences? {
        Defaults[.notificationSettingsSyncedPreferences]
            .flatMap { try? JSONDecoder().decode(LocalPreferences.self, from: $0) }
    }

    @MainActor
    private static func setLastSyncedPreferences(_ preferences: LocalPreferences, for signIn: SignIn) {
        Defaults[.notificationSettingsSyncedPreferences, for: signIn] = try? JSONEncoder().encode(preferences)
    }

    @MainActor
    static func pushBase(local: LocalPreferences) -> PushBase {
        if let lastSyncedPreferences { return .since(lastSyncedPreferences) }
        return Defaults[.notificationSettingsPushSendsEveryField] ? .everyField : .since(local)
    }

    @MainActor
    static func seedSyncedCopyOnSignIn(from local: LocalPreferences, for signIn: SignIn) {
        guard lastSyncedPreferences == nil, !Defaults[.notificationSettingsPushSendsEveryField] else { return }
        setLastSyncedPreferences(local, for: signIn)
    }

    /// The upgrade's seed of the copy, from Migrations/NotificationSettingsSyncedSeedMigration.swift: a
    /// push left pending sends every field, since its edit is not on the server yet.
    @MainActor
    static func seedOnUpgrade(local: LocalPreferences, pushPending: Bool, for signIn: SignIn) {
        if pushPending {
            Defaults[.notificationSettingsPushSendsEveryField, for: signIn] = true
        } else if lastSyncedPreferences == nil {
            setLastSyncedPreferences(local, for: signIn)
        }
    }

    @MainActor
    static func sectionTurnedOn(_ section: OwnedSection, local: LocalPreferences, for signIn: SignIn) {
        guard let lastSyncedPreferences else { return }
        setLastSyncedPreferences(lastSyncedPreferences.replacing(section, from: local), for: signIn)
    }

    @MainActor
    static func mergeSentFields(_ fields: [String: Any], of sent: LocalPreferences, for signIn: SignIn) {
        guard signIn.isCurrent else { return }
        setLastSyncedPreferences((lastSyncedPreferences ?? sent).mergeSentFields(fields, of: sent), for: signIn)
        Defaults[.notificationSettingsPushSendsEveryField, for: signIn] = false
    }

    @MainActor
    static func recordSyncedSections(_ sections: Set<OwnedSection>, of settled: LocalPreferences, for signIn: SignIn) {
        setLastSyncedPreferences(
            sections.reduce(lastSyncedPreferences ?? settled) { $0.replacing($1, from: settled) }, for: signIn
        )
    }

    @MainActor
    static func forget() {
        Defaults.reset(.notificationSettingsSyncedPreferences, .notificationSettingsPushSendsEveryField)
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

    static func changes(
        in updates: [String: Any],
        since synced: [String: Any],
        over existing: [String: Any]
    ) -> [String: Any] {
        updates.reduce(into: [:]) { changed, entry in
            guard let fields = entry.value as? [String: Any],
                  let server = existing[entry.key] as? [String: Any]
            else {
                changed[entry.key] = entry.value
                return
            }
            let before = synced[entry.key] as? [String: Any] ?? [:]
            changed[entry.key] = fields.filter { key, _ in
                let field: Set = mirroredOffsetKeys.contains(key) ? mirroredOffsetKeys : [key]
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

    /// docs/decisions/0002-notification-settings-json-merge.md
    @MainActor
    static func push(
        local: LocalPreferences,
        base: PushBase,
        client: SettingsDocumentClient,
        cloudSyncEnabled: Bool,
        syncAssignmentRemindersEnabled: Bool = true,
        syncLiveActivityEnabled: Bool = true,
        isCurrent: () -> Bool = { true },
        recordOnServer: ([String: Any]) -> Void = { _ in }
    ) async throws -> PushResult {
        guard cloudSyncEnabled else { return .skipped }

        var existing: [String: Any] = [:]
        var mode = SettingsWriteMode.create

        if case .stored(let data, let revision) = try await client.read(namespace: namespace) {
            existing = Self.object(from: data)
            mode = .replace(revision: revision)
        }

        var attempt = 0
        while true {
            guard isCurrent() else { return .skipped }
            let updates = try local.documentUpdates(
                existing: existing,
                since: base,
                includeAssignments: syncAssignmentRemindersEnabled,
                includeLiveActivity: syncLiveActivityEnabled
            )
            let merged = merging(updates, into: existing)
            if NSDictionary(dictionary: merged).isEqual(to: existing) {
                recordOnServer(updates)
                return isCurrent() ? .landed : .skipped
            }
            let body = try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
            let result = try await client.write(namespace: namespace, document: body, mode: mode)

            switch result {
            case .written:
                recordOnServer(updates)
                return isCurrent() ? .landed : .skipped
            case .conflict(let serverDocument, let serverRevision):
                attempt += 1
                guard attempt <= 1 else {
                    throw SyncError.conflictNotResolved
                }
                existing = Self.object(from: serverDocument)
                mode = .replace(revision: serverRevision)
            }
        }
    }

    static func object(from data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    static func canClearPendingMarker(
        _ result: PushResult,
        sent: LocalPreferences,
        current: LocalPreferences
    ) -> Bool {
        result == .landed && current == sent
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
        case snapshot(SettingsDocument)
    }

    enum ReconcileOutcome: Equatable, Sendable {
        case skipped
        case deferredToPendingPush
        case abandoned
        case settled(adopted: Set<OwnedSection>, seeded: Set<OwnedSection>)
    }
}
