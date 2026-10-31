#if os(iOS)
import Foundation

/// What the mail list is pointed at.
///
/// Mail2000 has no server-side "all mail" folder — there is no SPECIAL-USE, and IMAP has no
/// cross-folder view at all — so All mail is a client-side merge with no name any server
/// command would accept. Modelling it as its own case instead of a magic folder string is the
/// whole point: `real(name)` is the only case whose name may ever reach a `SELECT`, and every
/// `switch` over a selection has to state out loud what it does with `allMail`.
nonisolated enum MailFolderSelection: Hashable, Sendable {
    case real(String)

    case allMail

    /// The role folders All mail covers, ahead of every folder that has no role; Junk and Trash
    /// stay out.
    static let mergedRoles: [MailFolderRole] = [.inbox, .sent, .drafts]

    var realFolder: String? {
        if case .real(let name) = self { return name }
        return nil
    }

    func targets(roles: [MailFolderRole: String], others: [String]) -> [String] {
        switch self {
        case .real(let name): [name]
        case .allMail: Self.mergedRoles.compactMap { roles[$0] } + others
        }
    }
}

nonisolated struct MailListRow: Identifiable, Hashable, Sendable {
    var folder: String
    var summary: MailSummary

    var uid: UInt32 { summary.uid }

    /// NUL-joined. A folder name is modified UTF-7, which encodes every byte a mailbox name can
    /// carry but never produces a NUL, so no two (folder, uid) pairs can collide on this.
    var id: String { "\(folder)\u{0}\(summary.uid)" }
}
#endif
