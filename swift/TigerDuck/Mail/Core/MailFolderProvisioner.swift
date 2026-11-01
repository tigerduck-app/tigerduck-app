#if os(iOS)
import Foundation

nonisolated struct MailFolderUnavailable: Error, Equatable {
    var role: MailFolderRole
}

/// See docs/decisions/0016-mail-role-folder-provisioning.md.
nonisolated enum MailFolderProvisioner {
    struct Ensured: Equatable, Sendable {
        var name: String
        var roles: [MailFolderRole: String]
    }

    static let creatableRoles: Set<MailFolderRole> = [.sent, .drafts, .trash]

    static func ensure(
        _ role: MailFolderRole, in roles: [MailFolderRole: String], client: any MailClient
    ) async -> Ensured? {
        if let existing = roles[role] { return Ensured(name: existing, roles: roles) }
        guard creatableRoles.contains(role) else { return nil }
        // Mail2000 refuses a CREATE of an existing folder with a bare NO (no RFC 5530 ALREADYEXISTS).
        try? await client.createFolder(role.imapName)
        guard let available = try? await client.listFolders() else { return nil }
        let refreshed = MailFolderMap.resolve(available: available)
        guard let created = refreshed[role] else { return nil }
        return Ensured(name: created, roles: refreshed)
    }
}
#endif
