#if os(iOS)
import Foundation

nonisolated struct MailFolderUnavailable: Error, Equatable {
    var role: MailFolderRole
}

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
        try? await client.createFolder(role.imapName)
        guard let available = try? await client.listFolders() else { return nil }
        let refreshed = MailFolderMap.resolve(available: available)
        guard let created = refreshed[role] else { return nil }
        return Ensured(name: created, roles: refreshed)
    }
}
#endif
