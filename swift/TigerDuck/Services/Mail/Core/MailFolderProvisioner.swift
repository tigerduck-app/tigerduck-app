#if os(iOS)
import Foundation

/// A role folder an operation needed, which the account does not have and which could not be
/// created. Thrown by a caller that has nothing useful to do without it (saving a draft); the
/// callers that do have a fallback (filing a sent copy, deleting) never raise it.
nonisolated struct MailFolderUnavailable: Error, Equatable {
    var role: MailFolderRole
}

/// Creates a missing role folder at the moment an operation needs one, and re-resolves the role
/// map against a fresh `LIST` afterwards.
///
/// Mail2000 accounts are not guaranteed to have Sent, Drafts or Trash — one can be absent from
/// the start, and the user can delete any of them from the webmail at any time. Before this
/// existed the app assumed all three: a missing Drafts meant a draft could not be saved, a
/// missing Sent meant a sent mail vanished with no copy kept, and a missing Trash silently turned
/// Delete from "move to Trash" into an irreversible STORE `\Deleted` + EXPUNGE.
///
/// Three rules this type exists to enforce, all of them load-bearing:
///
/// 1. **Only `.sent`, `.drafts` and `.trash` are ever created.** `.junk` never is — the app never
///    writes to it, it is where the *server's* own spam classifier files mail, and a folder the
///    server does not know about achieves nothing there and may confuse filtering. `INBOX` never
///    is either: RFC 3501 guarantees it exists.
/// 2. **Nothing is created speculatively.** This is only ever called from inside the operation
///    that is about to need the folder — never at sign-in, never on a folder-list refresh, never
///    while resolving roles. Creating a folder is a real, visible change to someone's mail
///    account, so a user who only reads mail must never see one appear.
/// 3. **The role map is re-resolved from the server, not patched locally.** A caller holds the
///    map it was handed, and a folder created a moment ago is invisible to it until a fresh
///    `listFolders()` has been resolved through `MailFolderMap` — so the very operation that
///    created the folder would otherwise still fail for want of it.
///
/// The name passed to `createFolder` is the raw IMAP (modified UTF-7) form,
/// `MailFolderRole.imapName` — the same spelling `listFolders()` reports and every other folder
/// argument in `MailClient` already takes. Nothing in the chain below re-encodes it:
/// `IMAPServer.createMailbox` only runs the name through `resolveMailboxPath` (which prefixes an
/// advertised personal namespace and otherwise returns it unchanged) before handing it to
/// `MailboxName(ByteBuffer(string:))`, which stores raw bytes. Passing the decoded display name
/// would put raw UTF-8 on the wire where modified UTF-7 belongs; passing an already-encoded name
/// to a layer that encoded for us would double-encode it. `ensure` proves the round trip rather
/// than trusting it — see below.
nonisolated enum MailFolderProvisioner {
    /// One resolved role folder, together with the role map it was resolved from. Callers adopt
    /// `roles` wholesale: it came from a fresh `LIST`, so it is a better answer than the map they
    /// were holding, whether or not anything was actually created.
    struct Ensured: Equatable, Sendable {
        /// The folder's raw IMAP name, as `listFolders()` reports it.
        var name: String
        var roles: [MailFolderRole: String]
    }

    /// The only roles TigerDuck may bring into existence. See rule 1 above.
    static let creatableRoles: Set<MailFolderRole> = [.sent, .drafts, .trash]

    /// The folder for `role`, creating it if the account has none.
    ///
    /// Returns nil — and the caller falls back to whatever it did before this existed — when the
    /// role is one that must never be created, when the server refused the `CREATE`, or when the
    /// folder list that follows does not resolve the role back. Never throws: no caller of this
    /// may fail its own operation because a folder could not be made.
    ///
    /// A `CREATE` that fails is not assumed to mean failure. Mail2000 has no RFC 5530 response
    /// codes to say `[ALREADYEXISTS]` with, and two operations can race each other (or another
    /// client) to the same folder, so the only honest answer to "did the folder end up existing"
    /// is to ask the server. This therefore re-lists and re-resolves whether the `CREATE`
    /// succeeded or failed, and the *list* decides. That same re-resolve is what proves the name
    /// went out in a form the server understood: a mailbox created under a mangled or
    /// double-encoded name does not come back as this role, so it reports failure instead of
    /// handing the caller a folder that role resolution will never match again — which would make
    /// the next operation create yet another one.
    static func ensure(
        _ role: MailFolderRole, in roles: [MailFolderRole: String], client: any MailClient
    ) async -> Ensured? {
        if let existing = roles[role] { return Ensured(name: existing, roles: roles) }
        guard creatableRoles.contains(role) else { return nil }
        try? await client.createFolder(role.imapName)
        guard let available = try? await client.listFolders() else { return nil }
        let refreshed = MailFolderMap.resolve(available: available)
        guard let created = refreshed[role] else { return nil }
        return Ensured(name: created, roles: refreshed)
    }
}
#endif
