#if os(iOS)
import Foundation

/// Mail2000's own folders (Appendix A.1). The server has no SPECIAL-USE, so roles are
/// found by name; TigerDuck never creates a folder.
nonisolated enum MailFolderRole: String, CaseIterable, Sendable {
    case inbox, sent, drafts, junk, trash

    var imapName: String {
        switch self {
        case .inbox: "INBOX"
        case .sent: "&W8RO9lCZTv1TIw-"
        case .drafts: "&g0l6P1Mj-"
        case .junk: "&XuNUSk,hUyM-"
        case .trash: "&Vt5lNntS-"
        }
    }

    var decodedName: String {
        switch self {
        case .inbox: "INBOX"
        case .sent: "寄件備份匣"
        case .drafts: "草稿匣"
        case .junk: "廣告信匣"
        case .trash: "回收筒"
        }
    }

    var title: String {
        switch self {
        case .inbox: String(localized: "school_mail_folder_inbox")
        case .sent: String(localized: "school_mail_folder_sent")
        case .drafts: String(localized: "school_mail_folder_drafts")
        case .junk: String(localized: "school_mail_folder_junk")
        case .trash: String(localized: "school_mail_folder_trash")
        }
    }
}

nonisolated enum MailFolderMap {
    /// Exact IMAP-name match first, then one exact match on the decoded name. A role with
    /// neither is absent, and its chip is hidden.
    static func resolve(available: [String]) -> [MailFolderRole: String] {
        var result: [MailFolderRole: String] = [:]
        for role in MailFolderRole.allCases {
            if let exact = available.first(where: { $0 == role.imapName }) {
                result[role] = exact
            } else if let decoded = available.first(where: { ModifiedUTF7.decode($0) == role.decodedName }) {
                result[role] = decoded
            }
        }
        return result
    }

    /// Everything not mapped to a role, sorted by decoded name — the "More…" list.
    static func otherFolders(available: [String]) -> [String] {
        let mapped = Set(resolve(available: available).values)
        return available
            .filter { !mapped.contains($0) }
            .sorted { ModifiedUTF7.decode($0).localizedStandardCompare(ModifiedUTF7.decode($1)) == .orderedAscending }
    }
}
#endif
