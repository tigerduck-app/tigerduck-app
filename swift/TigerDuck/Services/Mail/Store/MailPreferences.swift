#if os(iOS)
import Defaults
import Foundation

nonisolated struct MailCheckRecord: Codable, Equatable, Sendable {
    var date: Date
    var trigger: String
    var result: String
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

/// Backed by the `Defaults` library, on a suite chosen at `init`. Production callers use the
/// no-argument initializer (the app's real `UserDefaults.standard`); tests inject a per-test
/// `UserDefaults(suiteName:)` so they never read, write or `reset()` the app's real
/// `school_mail_*` keys — following this repo's existing isolation idiom
/// (`CloudSyncPreferenceTests.withIsolatedKey`, `ClockCoreTests`'s per-test suite + persistent
/// domain removal).
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

    private let studentIDKey: Defaults.Key<String?>
    private let displayNameKey: Defaults.Key<String?>
    private let notificationsEnabledKey: Defaults.Key<Bool>
    private let inboxUIDValidityKey: Defaults.Key<Int?>
    private let inboxNextUIDKey: Defaults.Key<Int?>
    private let authFailedKey: Defaults.Key<Bool>
    private let demoActiveKey: Defaults.Key<Bool>
    private let lastCheckAtKey: Defaults.Key<Date?>
    /// JSON-encoded `[OwnedDeletedRecord]` — never a string key joined with a separator, since a
    /// Mail2000 folder name (modified UTF-7, arbitrary bytes) can contain any character,
    /// including whatever separator a joined key would pick.
    private let ownedDeletedKey: Defaults.Key<Data?>
    private let diagnosticsKey: Defaults.Key<Data?>

    /// Guards the `ownedDeletedRecords` read-modify-write in `setOwnedDeleted`: two concurrent
    /// calls for different folders (e.g. a background check expunging one folder while the user
    /// deletes mail in another) must not read the same snapshot and each write back a list
    /// missing the other's entry. Mirrors `MailCache`'s lock. The scalar properties below don't
    /// need it — each is a single `Defaults[key]` get/set, not a compound operation.
    private let lock = NSLock()

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
    var diagnostics: [MailCheckRecord] {
        get {
            guard let data = Defaults[diagnosticsKey] else { return [] }
            return (try? JSONDecoder().decode([MailCheckRecord].self, from: data)) ?? []
        }
        set { Defaults[diagnosticsKey] = try? JSONEncoder().encode(newValue) }
    }

    /// Not locked itself — only ever called from within a `lock.withLock` block below.
    private var ownedDeletedRecords: [OwnedDeletedRecord] {
        get {
            guard let data = Defaults[ownedDeletedKey] else { return [] }
            return (try? JSONDecoder().decode([OwnedDeletedRecord].self, from: data)) ?? []
        }
        set { Defaults[ownedDeletedKey] = try? JSONEncoder().encode(newValue) }
    }

    func ownedDeleted(folder: String, uidValidity: UInt32) -> OwnedDeleted {
        lock.withLock {
            guard let record = ownedDeletedRecords.first(where: { $0.folder == folder && $0.uidValidity == uidValidity }) else {
                return OwnedDeleted(folder: folder, uidValidity: uidValidity, uids: [])
            }
            return OwnedDeleted(folder: folder, uidValidity: uidValidity, uids: record.uids)
        }
    }

    func setOwnedDeleted(_ owned: OwnedDeleted) {
        lock.withLock {
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
