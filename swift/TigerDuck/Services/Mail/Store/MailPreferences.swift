#if os(iOS)
import Defaults
import Foundation

nonisolated struct MailCheckRecord: Codable, Equatable, Sendable {
    var date: Date
    var trigger: String
    var result: String
}

nonisolated protocol MailPreferences: AnyObject, Sendable {
    var studentID: String? { get set }
    var displayName: String? { get set }
    var notificationsEnabled: Bool { get set }
    var inboxUIDValidity: UInt32? { get set }
    var inboxNextUID: UInt32? { get set }
    var authFailed: Bool { get set }
    var demoActive: Bool { get set }
    var lastCheckAt: Date? { get set }
    var diagnostics: [MailCheckRecord] { get set }
    var cacheWipePending: Bool { get set }

    func ownedDeleted(folder: String, uidValidity: UInt32) -> OwnedDeleted
    func setOwnedDeleted(_ owned: OwnedDeleted)

    func reset()
}

nonisolated final class DefaultsMailPreferences: MailPreferences, @unchecked Sendable {
    private struct OwnedDeletedRecord: Codable, Equatable, Sendable {
        var folder: String
        var uidValidity: UInt32
        var uids: Set<UInt32>
    }

    private let studentIDKey: Defaults.Key<String?>
    private let displayNameKey: Defaults.Key<String?>
    private let notificationsEnabledKey: Defaults.Key<Bool>
    private let inboxUIDValidityKey: Defaults.Key<Int?>
    private let inboxNextUIDKey: Defaults.Key<Int?>
    private let authFailedKey: Defaults.Key<Bool>
    private let demoActiveKey: Defaults.Key<Bool>
    private let lastCheckAtKey: Defaults.Key<Date?>
    private let ownedDeletedKey: Defaults.Key<Data?>
    private let diagnosticsKey: Defaults.Key<Data?>
    private let cacheWipePendingKey: Defaults.Key<Bool>

    private static let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        studentIDKey = Defaults.Key<String?>("school_mail_student_id", suite: defaults)
        displayNameKey = Defaults.Key<String?>("school_mail_display_name", suite: defaults)
        notificationsEnabledKey = Defaults.Key<Bool>("school_mail_notifications_enabled", default: true, suite: defaults)
        inboxUIDValidityKey = Defaults.Key<Int?>("school_mail_inbox_uid_validity", suite: defaults)
        inboxNextUIDKey = Defaults.Key<Int?>("school_mail_inbox_next_uid", suite: defaults)
        authFailedKey = Defaults.Key<Bool>("school_mail_auth_failed", default: false, suite: defaults)
        demoActiveKey = Defaults.Key<Bool>("school_mail_demo_active", default: false, suite: defaults)
        lastCheckAtKey = Defaults.Key<Date?>("school_mail_last_check_at", suite: defaults)
        ownedDeletedKey = Defaults.Key<Data?>("school_mail_owned_deleted", suite: defaults)
        diagnosticsKey = Defaults.Key<Data?>("school_mail_diagnostics", suite: defaults)
        cacheWipePendingKey = Defaults.Key<Bool>("school_mail_cache_wipe_pending", default: false, suite: defaults)
    }

    var studentID: String? {
        get { Defaults[studentIDKey] }
        set { Defaults[studentIDKey] = newValue }
    }
    var displayName: String? {
        get { Defaults[displayNameKey] }
        set { Defaults[displayNameKey] = newValue }
    }
    var notificationsEnabled: Bool {
        get { Defaults[notificationsEnabledKey] }
        set { Defaults[notificationsEnabledKey] = newValue }
    }
    var inboxUIDValidity: UInt32? {
        get { Defaults[inboxUIDValidityKey].map { UInt32(truncatingIfNeeded: $0) } }
        set { Defaults[inboxUIDValidityKey] = newValue.map(Int.init) }
    }
    var inboxNextUID: UInt32? {
        get { Defaults[inboxNextUIDKey].map { UInt32(truncatingIfNeeded: $0) } }
        set { Defaults[inboxNextUIDKey] = newValue.map(Int.init) }
    }
    var authFailed: Bool {
        get { Defaults[authFailedKey] }
        set { Defaults[authFailedKey] = newValue }
    }
    var demoActive: Bool {
        get { Defaults[demoActiveKey] }
        set { Defaults[demoActiveKey] = newValue }
    }
    var lastCheckAt: Date? {
        get { Defaults[lastCheckAtKey] }
        set { Defaults[lastCheckAtKey] = newValue }
    }
    var cacheWipePending: Bool {
        get { Defaults[cacheWipePendingKey] }
        set { Defaults[cacheWipePendingKey] = newValue }
    }
    var diagnostics: [MailCheckRecord] {
        get {
            guard let data = Defaults[diagnosticsKey] else { return [] }
            return (try? JSONDecoder().decode([MailCheckRecord].self, from: data)) ?? []
        }
        set { Defaults[diagnosticsKey] = try? JSONEncoder().encode(newValue) }
    }

    private var ownedDeletedRecords: [OwnedDeletedRecord] {
        get {
            guard let data = Defaults[ownedDeletedKey] else { return [] }
            return (try? JSONDecoder().decode([OwnedDeletedRecord].self, from: data)) ?? []
        }
        set { Defaults[ownedDeletedKey] = try? JSONEncoder().encode(newValue) }
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
            studentIDKey, displayNameKey, notificationsEnabledKey,
            inboxUIDValidityKey, inboxNextUIDKey, authFailedKey,
            demoActiveKey, lastCheckAtKey, ownedDeletedKey, diagnosticsKey
        )
    }
}
#endif
