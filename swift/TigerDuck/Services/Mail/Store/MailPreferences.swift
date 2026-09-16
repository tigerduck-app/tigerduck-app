#if os(iOS)
import Defaults
import Foundation

nonisolated struct MailCheckRecord: Codable, Equatable, Sendable {
    var date: Date
    var trigger: String
    var result: String
}

nonisolated extension Defaults.Keys {
    static let schoolMailStudentID = Key<String?>("school_mail_student_id")
    static let schoolMailDisplayName = Key<String?>("school_mail_display_name")
    static let schoolMailNotificationsEnabled = Key<Bool>("school_mail_notifications_enabled", default: true)
    static let schoolMailInboxUIDValidity = Key<Int?>("school_mail_inbox_uid_validity")
    static let schoolMailInboxNextUID = Key<Int?>("school_mail_inbox_next_uid")
    static let schoolMailAuthFailed = Key<Bool>("school_mail_auth_failed", default: false)
    static let schoolMailDemoActive = Key<Bool>("school_mail_demo_active", default: false)
    static let schoolMailLastCheckAt = Key<Date?>("school_mail_last_check_at")
    /// JSON-encoded `[OwnedDeletedRecord]` — never a string key joined with a separator, since a
    /// Mail2000 folder name (modified UTF-7, arbitrary bytes) can contain any character,
    /// including whatever separator a joined key would pick.
    static let schoolMailOwnedDeleted = Key<Data?>("school_mail_owned_deleted")
    static let schoolMailDiagnostics = Key<Data?>("school_mail_diagnostics")
}

/// School Mail's non-secret state: the student ID (the signed-in signal), display name,
/// the new-mail marker, and diagnostics. The password lives in `MailCredentialStore`.
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

    /// UIDs TigerDuck flagged `\Deleted` in `folder` and hasn't been able to expunge yet, still
    /// waiting from the UIDVALIDITY generation they were recorded under. Empty when nothing is
    /// stored for that folder+validity pair — including when the folder has a stored entry
    /// recorded under a *different* UIDVALIDITY, since that entry no longer means anything once
    /// the folder has been recreated server-side.
    func ownedDeleted(folder: String, uidValidity: UInt32) -> OwnedDeleted
    /// Replaces whatever is stored for `owned.folder` (at any UIDVALIDITY) with `owned`. An empty
    /// `uids` removes the folder's entry entirely rather than storing an empty one.
    func setOwnedDeleted(_ owned: OwnedDeleted)

    func reset()
}

nonisolated final class DefaultsMailPreferences: MailPreferences, @unchecked Sendable {
    /// The Codable twin of `OwnedDeleted` used only for persistence. `OwnedDeleted` itself is
    /// declared in `MailMover.swift` without `Codable`; Swift only synthesizes `Codable` for a
    /// conformance declared in the same file as the type, so this store keeps its own record
    /// shape and converts at the boundary instead of extending `OwnedDeleted` from here.
    private struct OwnedDeletedRecord: Codable, Equatable, Sendable {
        var folder: String
        var uidValidity: UInt32
        var uids: Set<UInt32>
    }

    var studentID: String? {
        get { Defaults[.schoolMailStudentID] }
        set { Defaults[.schoolMailStudentID] = newValue }
    }
    var displayName: String? {
        get { Defaults[.schoolMailDisplayName] }
        set { Defaults[.schoolMailDisplayName] = newValue }
    }
    var notificationsEnabled: Bool {
        get { Defaults[.schoolMailNotificationsEnabled] }
        set { Defaults[.schoolMailNotificationsEnabled] = newValue }
    }
    var inboxUIDValidity: UInt32? {
        get { Defaults[.schoolMailInboxUIDValidity].map { UInt32(truncatingIfNeeded: $0) } }
        set { Defaults[.schoolMailInboxUIDValidity] = newValue.map(Int.init) }
    }
    var inboxNextUID: UInt32? {
        get { Defaults[.schoolMailInboxNextUID].map { UInt32(truncatingIfNeeded: $0) } }
        set { Defaults[.schoolMailInboxNextUID] = newValue.map(Int.init) }
    }
    var authFailed: Bool {
        get { Defaults[.schoolMailAuthFailed] }
        set { Defaults[.schoolMailAuthFailed] = newValue }
    }
    var demoActive: Bool {
        get { Defaults[.schoolMailDemoActive] }
        set { Defaults[.schoolMailDemoActive] = newValue }
    }
    var lastCheckAt: Date? {
        get { Defaults[.schoolMailLastCheckAt] }
        set { Defaults[.schoolMailLastCheckAt] = newValue }
    }
    var diagnostics: [MailCheckRecord] {
        get {
            guard let data = Defaults[.schoolMailDiagnostics] else { return [] }
            return (try? JSONDecoder().decode([MailCheckRecord].self, from: data)) ?? []
        }
        set { Defaults[.schoolMailDiagnostics] = try? JSONEncoder().encode(newValue) }
    }

    private var ownedDeletedRecords: [OwnedDeletedRecord] {
        get {
            guard let data = Defaults[.schoolMailOwnedDeleted] else { return [] }
            return (try? JSONDecoder().decode([OwnedDeletedRecord].self, from: data)) ?? []
        }
        set { Defaults[.schoolMailOwnedDeleted] = try? JSONEncoder().encode(newValue) }
    }

    func ownedDeleted(folder: String, uidValidity: UInt32) -> OwnedDeleted {
        guard let record = ownedDeletedRecords.first(where: { $0.folder == folder && $0.uidValidity == uidValidity }) else {
            return OwnedDeleted(folder: folder, uidValidity: uidValidity, uids: [])
        }
        return OwnedDeleted(folder: folder, uidValidity: uidValidity, uids: record.uids)
    }

    func setOwnedDeleted(_ owned: OwnedDeleted) {
        var records = ownedDeletedRecords.filter { $0.folder != owned.folder }
        if !owned.uids.isEmpty {
            records.append(OwnedDeletedRecord(folder: owned.folder, uidValidity: owned.uidValidity, uids: owned.uids))
        }
        ownedDeletedRecords = records
    }

    func reset() {
        Defaults.reset(
            .schoolMailStudentID, .schoolMailDisplayName, .schoolMailNotificationsEnabled,
            .schoolMailInboxUIDValidity, .schoolMailInboxNextUID, .schoolMailAuthFailed,
            .schoolMailDemoActive, .schoolMailLastCheckAt, .schoolMailOwnedDeleted, .schoolMailDiagnostics
        )
    }
}
#endif
