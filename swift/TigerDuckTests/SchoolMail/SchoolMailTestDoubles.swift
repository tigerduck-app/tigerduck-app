#if os(iOS)
import Foundation
@testable import TigerDuck

final class InMemoryMailPreferences: MailPreferences, @unchecked Sendable {
    private let lock = NSLock()

    private var _studentID: String?
    private var _displayName: String?
    private var _notificationsEnabled = true
    private var _inboxUIDValidity: UInt32?
    private var _inboxNextUID: UInt32?
    private var _authFailed = false
    private var _demoActive = false
    private var _lastCheckAt: Date?
    private var _diagnostics: [MailCheckRecord] = []
    /// Keyed by folder only (never a joined string key): a stored entry is returned by
    /// `ownedDeleted` only when its UIDVALIDITY also matches, mirroring the persisted store.
    private var ownedByFolder: [String: OwnedDeleted] = [:]

    var studentID: String? {
        get { lock.withLock { _studentID } }
        set { lock.withLock { _studentID = newValue } }
    }
    var displayName: String? {
        get { lock.withLock { _displayName } }
        set { lock.withLock { _displayName = newValue } }
    }
    var notificationsEnabled: Bool {
        get { lock.withLock { _notificationsEnabled } }
        set { lock.withLock { _notificationsEnabled = newValue } }
    }
    var inboxUIDValidity: UInt32? {
        get { lock.withLock { _inboxUIDValidity } }
        set { lock.withLock { _inboxUIDValidity = newValue } }
    }
    var inboxNextUID: UInt32? {
        get { lock.withLock { _inboxNextUID } }
        set { lock.withLock { _inboxNextUID = newValue } }
    }
    var authFailed: Bool {
        get { lock.withLock { _authFailed } }
        set { lock.withLock { _authFailed = newValue } }
    }
    var demoActive: Bool {
        get { lock.withLock { _demoActive } }
        set { lock.withLock { _demoActive = newValue } }
    }
    var lastCheckAt: Date? {
        get { lock.withLock { _lastCheckAt } }
        set { lock.withLock { _lastCheckAt = newValue } }
    }
    var diagnostics: [MailCheckRecord] {
        get { lock.withLock { _diagnostics } }
        set { lock.withLock { _diagnostics = newValue } }
    }

    func ownedDeleted(folder: String, uidValidity: UInt32) -> OwnedDeleted {
        lock.withLock {
            guard let stored = ownedByFolder[folder], stored.uidValidity == uidValidity else {
                return OwnedDeleted(folder: folder, uidValidity: uidValidity, uids: [])
            }
            return stored
        }
    }

    func setOwnedDeleted(_ owned: OwnedDeleted) {
        lock.withLock {
            if owned.uids.isEmpty {
                ownedByFolder[owned.folder] = nil
            } else {
                ownedByFolder[owned.folder] = owned
            }
        }
    }

    func reset() {
        lock.withLock {
            _studentID = nil
            _displayName = nil
            _notificationsEnabled = true
            _inboxUIDValidity = nil
            _inboxNextUID = nil
            _authFailed = false
            _demoActive = false
            _lastCheckAt = nil
            _diagnostics = []
            ownedByFolder = [:]
        }
    }
}

final class InMemoryMailSecretStorage: MailSecretStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func save(_ value: String, forKey key: String) throws { lock.withLock { values[key] = value } }
    func load(forKey key: String) -> String? { lock.withLock { values[key] } }
    func delete(forKey key: String) { lock.withLock { values[key] = nil } }
    func deleteAll() { lock.withLock { values = [:] } }
}

enum SchoolMailTestDoubles {
    static func temporaryCache(bodyLimitBytes: Int = MailConstants.bodyCacheLimitBytes) -> MailCache {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SchoolMailTests-\(UUID().uuidString)", isDirectory: true)
        return MailCache(directory: directory, bodyLimitBytes: bodyLimitBytes)
    }

    static func summary(uid: UInt32, seen: Bool = false) -> MailSummary {
        MailSummary(uid: uid, fromName: "教務處", fromAddress: "office@mail.ntust.edu.tw", to: nil, cc: nil,
                    subject: "公告 \(uid)", date: Date(timeIntervalSince1970: 1_789_000_000), isSeen: seen,
                    isAnswered: false, isDeleted: false, size: 10, hasAttachments: false, isExternal: false)
    }
}
#endif
