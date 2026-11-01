#if os(iOS)
import Defaults
import Foundation

nonisolated final class MailSettingsStore: MailPreferenceFields, @unchecked Sendable {
    static let shared = MailSettingsStore()

    private struct OwnedDeletedRecord: Codable, Equatable, Sendable {
        var folder: String
        var uidValidity: UInt32
        var uids: Set<UInt32>
    }

    private struct Keys {
        let studentID: Defaults.Key<String?>
        let displayName: Defaults.Key<String?>
        let notificationsEnabled: Defaults.Key<Bool>
        let inboxUIDValidity: Defaults.Key<Int?>
        let inboxNextUID: Defaults.Key<Int?>
        let authFailed: Defaults.Key<Bool>
        let demoActive: Defaults.Key<Bool>
        let lastCheckAt: Defaults.Key<Date?>
        let ownedDeleted: Defaults.Key<Data?>
        let diagnostics: Defaults.Key<Data?>
        let cacheWipePending: Defaults.Key<Bool>
        let muteSettings: Defaults.Key<Data?>
        let inboxMutedUIDs: Defaults.Key<Data?>

        init(defaults: UserDefaults) {
            studentID = Defaults.Key<String?>("school_mail_student_id", suite: defaults)
            displayName = Defaults.Key<String?>("school_mail_display_name", suite: defaults)
            notificationsEnabled = Defaults.Key<Bool>("school_mail_notifications_enabled", default: true, suite: defaults)
            inboxUIDValidity = Defaults.Key<Int?>("school_mail_inbox_uid_validity", suite: defaults)
            inboxNextUID = Defaults.Key<Int?>("school_mail_inbox_next_uid", suite: defaults)
            authFailed = Defaults.Key<Bool>("school_mail_auth_failed", default: false, suite: defaults)
            demoActive = Defaults.Key<Bool>("school_mail_demo_active", default: false, suite: defaults)
            lastCheckAt = Defaults.Key<Date?>("school_mail_last_check_at", suite: defaults)
            ownedDeleted = Defaults.Key<Data?>("school_mail_owned_deleted", suite: defaults)
            diagnostics = Defaults.Key<Data?>("school_mail_diagnostics", suite: defaults)
            cacheWipePending = Defaults.Key<Bool>("school_mail_cache_wipe_pending", default: false, suite: defaults)
            muteSettings = Defaults.Key<Data?>("school_mail_mute_settings", suite: defaults)
            inboxMutedUIDs = Defaults.Key<Data?>("school_mail_inbox_muted_uids", suite: defaults)
        }
    }

    private let keys: Keys

    private static let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        keys = Keys(defaults: defaults)
    }

    var studentID: String? {
        get { Defaults[keys.studentID] }
        set { Defaults[keys.studentID] = newValue }
    }
    var displayName: String? {
        get { Defaults[keys.displayName] }
        set { Defaults[keys.displayName] = newValue }
    }
    var notificationsEnabled: Bool {
        get { Defaults[keys.notificationsEnabled] }
        set { Defaults[keys.notificationsEnabled] = newValue }
    }
    var inboxUIDValidity: UInt32? {
        get { Defaults[keys.inboxUIDValidity].map { UInt32(truncatingIfNeeded: $0) } }
        set { Defaults[keys.inboxUIDValidity] = newValue.map(Int.init) }
    }
    var inboxNextUID: UInt32? {
        get { Defaults[keys.inboxNextUID].map { UInt32(truncatingIfNeeded: $0) } }
        set { Defaults[keys.inboxNextUID] = newValue.map(Int.init) }
    }
    var authFailed: Bool {
        get { Defaults[keys.authFailed] }
        set { Defaults[keys.authFailed] = newValue }
    }
    var demoActive: Bool {
        get { Defaults[keys.demoActive] }
        set { Defaults[keys.demoActive] = newValue }
    }
    var lastCheckAt: Date? {
        get { Defaults[keys.lastCheckAt] }
        set { Defaults[keys.lastCheckAt] = newValue }
    }
    var cacheWipePending: Bool {
        get { Defaults[keys.cacheWipePending] }
        set { Defaults[keys.cacheWipePending] = newValue }
    }
    var diagnostics: [MailCheckRecord] {
        get {
            guard let data = Defaults[keys.diagnostics] else { return [] }
            return (try? JSONDecoder().decode([MailCheckRecord].self, from: data)) ?? []
        }
        set { Defaults[keys.diagnostics] = try? JSONEncoder().encode(newValue) }
    }
    var muteSettings: MailMuteSettings {
        get {
            guard let data = Defaults[keys.muteSettings] else { return MailMuteSettings() }
            return (try? JSONDecoder().decode(MailMuteSettings.self, from: data)) ?? MailMuteSettings()
        }
        set { Defaults[keys.muteSettings] = try? JSONEncoder().encode(newValue) }
    }
    var inboxMutedUIDs: MailMutedUIDs? {
        get { Defaults[keys.inboxMutedUIDs].flatMap { try? JSONDecoder().decode(MailMutedUIDs.self, from: $0) } }
        set { Defaults[keys.inboxMutedUIDs] = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    private var ownedDeletedRecords: [OwnedDeletedRecord] {
        get {
            guard let data = Defaults[keys.ownedDeleted] else { return [] }
            return (try? JSONDecoder().decode([OwnedDeletedRecord].self, from: data)) ?? []
        }
        set { Defaults[keys.ownedDeleted] = try? JSONEncoder().encode(newValue) }
    }

    func ownedDeleted(folder: String, uidValidity: UInt32) -> OwnedDeleted {
        Self.lock.withLock {
            guard let record = ownedDeletedRecords.first(where: { $0.folder == folder && $0.uidValidity == uidValidity }) else {
                return OwnedDeleted(folder: folder, uidValidity: uidValidity, uids: [])
            }
            return OwnedDeleted(folder: folder, uidValidity: uidValidity, uids: record.uids)
        }
    }

    func setOwnedDeleted(_ owned: OwnedDeleted) {
        Self.lock.withLock {
            var records = ownedDeletedRecords.filter { $0.folder != owned.folder }
            if !owned.uids.isEmpty {
                records.append(OwnedDeletedRecord(folder: owned.folder, uidValidity: owned.uidValidity, uids: owned.uids))
            }
            ownedDeletedRecords = records
        }
    }

    func reset() {
        Defaults.reset(
            keys.studentID, keys.displayName, keys.notificationsEnabled,
            keys.inboxUIDValidity, keys.inboxNextUID, keys.authFailed,
            keys.demoActive, keys.lastCheckAt, keys.ownedDeleted, keys.diagnostics, keys.muteSettings,
            keys.inboxMutedUIDs
        )
    }
}

extension MailSettingsStore: AccountScoped {
    @MainActor static func forgetAccount(in storage: AccountStorage) {
        storage.mailPreferences.reset()
    }
}
#endif
