#if os(iOS)
import Defaults
import Foundation

nonisolated struct MailCheckRecord: Codable, Equatable, Sendable {
    var date: Date
    var trigger: String
    var result: String
}

nonisolated struct MailMutedUIDs: Codable, Equatable, Sendable {
    var uidValidity: UInt32
    var uids: Set<UInt32>
}

/// School Mail's stored account. Its fields change only through `change(for:_:)`, which drops a
/// write whose sign-in has ended; `cacheWipePending` belongs to the sign-out's cache wipe, which
/// runs after the sign-in ended.
nonisolated protocol MailPreferences: AnyObject, Sendable {
    var studentID: String? { get }
    var displayName: String? { get }
    var notificationsEnabled: Bool { get }
    var inboxUIDValidity: UInt32? { get }
    var inboxNextUID: UInt32? { get }
    var authFailed: Bool { get }
    var demoActive: Bool { get }
    var lastCheckAt: Date? { get }
    var diagnostics: [MailCheckRecord] { get }
    var muteSettings: MailMuteSettings { get }
    var inboxMutedUIDs: MailMutedUIDs? { get }
    var cacheWipePending: Bool { get set }

    func ownedDeleted(folder: String, uidValidity: UInt32) -> OwnedDeleted
    func change(for signIn: SignIn, _ write: (any MailPreferenceFields) -> Void)

    func reset()
}

/// The writable fields of `MailPreferences`, handed out by `change(for:_:)`.
nonisolated protocol MailPreferenceFields: MailPreferences {
    var studentID: String? { get set }
    var displayName: String? { get set }
    var notificationsEnabled: Bool { get set }
    var inboxUIDValidity: UInt32? { get set }
    var inboxNextUID: UInt32? { get set }
    var authFailed: Bool { get set }
    var demoActive: Bool { get set }
    var lastCheckAt: Date? { get set }
    var diagnostics: [MailCheckRecord] { get set }
    var muteSettings: MailMuteSettings { get set }
    var inboxMutedUIDs: MailMutedUIDs? { get set }

    func setOwnedDeleted(_ owned: OwnedDeleted)
}

extension MailPreferenceFields {
    func change(for signIn: SignIn, _ write: (any MailPreferenceFields) -> Void) {
        guard signIn.isCurrent else { return }
        write(self)
    }
}

#endif
