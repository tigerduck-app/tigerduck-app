#if os(iOS)
import Foundation

nonisolated enum MailFolderSelection: Hashable, Sendable {
    case real(String)

    case allMail

    static let mergedRoles: [MailFolderRole] = [.inbox, .sent]

    var realFolder: String? {
        if case .real(let name) = self { return name }
        return nil
    }

    func targets(roles: [MailFolderRole: String]) -> [String] {
        switch self {
        case .real(let name): [name]
        case .allMail: Self.mergedRoles.compactMap { roles[$0] }
        }
    }
}

nonisolated struct MailListRow: Identifiable, Hashable, Sendable {
    var folder: String
    var summary: MailSummary

    var uid: UInt32 { summary.uid }

    var id: String { "\(folder)\u{0}\(summary.uid)" }
}
#endif
