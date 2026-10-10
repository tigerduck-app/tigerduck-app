#if os(iOS)
import Foundation

/// A role folder an operation needed, which the account does not have and which could not be
/// created. Thrown by a caller that has nothing useful to do without it (saving a draft); the
/// callers that do have a fallback (filing a sent copy, deleting) never raise it.
nonisolated struct MailFolderUnavailable: Error, Equatable {
    var role: MailFolderRole
}

/// Creates a missing role folder when an operation needs one, then re-resolves the role map from a
/// fresh `LIST`. Mail2000 accounts need not have Sent, Drafts or Trash. Three rules: (1) only
/// those three are ever created: `.junk` belongs to the server's spam filter, and RFC 3501
/// guarantees `INBOX`. (2) Nothing is created speculatively, as a new folder is a visible change
/// to the account. (3) The map is re-resolved from the server, not patched, because the caller's
/// map cannot see the new folder. Roles resolve by name, so the same names are created on any
/// server. `createFolder` gets the raw modified UTF-7 `MailFolderRole.imapName`, which nothing
/// below re-encodes. See docs/decisions/0016-mail-role-folder-provisioning.md.
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

    /// The folder for `role`, creating it if the account has none. Returns nil, and the caller
    /// falls back, when the role must never be created or a fresh `LIST` does not resolve it back.
    /// Never throws: no caller may fail its own operation because a folder could not be made.
    ///
    /// The list decides, not the `CREATE` result: Mail2000 has no RFC 5530 `[ALREADYEXISTS]`, and
    /// two operations, or another client, can race to the same folder. The re-resolve also proves
    /// the name went out in a form the server understood: a mangled or double-encoded name never
    /// resolves to this role, and handing it back would make the next operation create another.
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
