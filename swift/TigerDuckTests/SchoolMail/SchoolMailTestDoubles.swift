#if os(iOS)
import Foundation
@testable import TigerDuck

final class InMemoryMailPreferences: MailPreferences, @unchecked Sendable {
    var studentID: String?
    var displayName: String?
    var notificationsEnabled = true
    var inboxUIDValidity: UInt32?
    var inboxNextUID: UInt32?
    var authFailed = false
    var demoActive = false
    var lastCheckAt: Date?
    var diagnostics: [MailCheckRecord] = []

    /// Keyed by folder only (never a joined string key): a stored entry is returned by
    /// `ownedDeleted` only when its UIDVALIDITY also matches, mirroring the persisted store.
    private var ownedByFolder: [String: OwnedDeleted] = [:]

    func ownedDeleted(folder: String, uidValidity: UInt32) -> OwnedDeleted {
        guard let stored = ownedByFolder[folder], stored.uidValidity == uidValidity else {
            return OwnedDeleted(folder: folder, uidValidity: uidValidity, uids: [])
        }
        return stored
    }

    func setOwnedDeleted(_ owned: OwnedDeleted) {
        if owned.uids.isEmpty {
            ownedByFolder[owned.folder] = nil
        } else {
            ownedByFolder[owned.folder] = owned
        }
    }

    func reset() {
        studentID = nil
        displayName = nil
        notificationsEnabled = true
        inboxUIDValidity = nil
        inboxNextUID = nil
        authFailed = false
        demoActive = false
        lastCheckAt = nil
        diagnostics = []
        ownedByFolder = [:]
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
