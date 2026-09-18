#if os(iOS)
import Foundation

/// What the mail list is pointed at.
///
/// Mail2000 has no server-side "all mail" folder — there is no SPECIAL-USE, and IMAP has no
/// cross-folder view at all — so 所有信件 is a client-side merge with no name any server
/// command would accept. Modelling it as its own case instead of a magic folder string is the
/// whole point: `real(name)` is the only case whose name may ever reach a `SELECT`, and every
/// `switch` over a selection has to state out loud what it does with `allMail`.
nonisolated enum MailFolderSelection: Hashable, Sendable {
    /// A folder the server actually has, named exactly as `LIST` reported it.
    case real(String)

    /// 所有信件: `mergedRoles` merged client-side, newest first. Never a folder name.
    case allMail

    /// The only folders 所有信件 merges — the two that hold real correspondence. Drafts, junk,
    /// trash and user folders stay out on purpose: a merged view is a read view over mail the
    /// student actually exchanged, and sweeping trash or drafts into it would put those
    /// messages one tap away from actions whose safety rules are written per folder.
    static let mergedRoles: [MailFolderRole] = [.inbox, .sent]

    /// The one real folder this selection names, or nil for 所有信件 — for the callers that
    /// need a single folder and have to cope with there not being one.
    var realFolder: String? {
        if case .real(let name) = self { return name }
        return nil
    }

    /// The real folders this selection reads, resolved against what the server actually has.
    /// Every server call resolves through here, so no synthetic name can reach a `SELECT`:
    /// 所有信件 becomes the folders it merges, and a selection that resolves to nothing
    /// simply reads nothing.
    func targets(roles: [MailFolderRole: String]) -> [String] {
        switch self {
        case .real(let name): [name]
        case .allMail: Self.mergedRoles.compactMap { roles[$0] }
        }
    }
}

/// One list row: a `summary` together with the real folder it lives in.
///
/// A UID is unique only within its own folder, so 收件匣 and 寄件備份 routinely both hold a
/// UID 42 belonging to two entirely different mails. Every row therefore carries its own
/// folder, and everything a row leads to — opening it, marking it read, moving or deleting it
/// — addresses `folder`, never whichever folder chip happens to be selected. `id` is that
/// (folder, uid) identity as one string, for `ForEach` keys, for the swipe gesture's state and
/// for finding a row again after an action.
nonisolated struct MailListRow: Identifiable, Hashable, Sendable {
    var folder: String
    var summary: MailSummary

    var uid: UInt32 { summary.uid }

    /// NUL-joined. A folder name is modified UTF-7, which encodes every byte a mailbox name can
    /// carry but never produces a NUL, so no two (folder, uid) pairs can collide on this.
    var id: String { "\(folder)\u{0}\(summary.uid)" }
}
#endif
