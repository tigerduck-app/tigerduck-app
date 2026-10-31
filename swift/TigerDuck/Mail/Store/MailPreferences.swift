#if os(iOS)
import Defaults
import Foundation

nonisolated struct MailCheckRecord: Codable, Equatable, Sendable {
    var date: Date
    var trigger: String
    var result: String
}

/// Inbox UIDs a mute setting passed over, kept while the marker is below them.
nonisolated struct MailMutedUIDs: Codable, Equatable, Sendable {
    var uidValidity: UInt32
    var uids: Set<UInt32>
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
    var muteSettings: MailMuteSettings { get set }
    var inboxMutedUIDs: MailMutedUIDs? { get set }

    func ownedDeleted(folder: String, uidValidity: UInt32) -> OwnedDeleted
    func setOwnedDeleted(_ owned: OwnedDeleted)

    func reset()
}

#endif
