#if os(iOS)
import SwiftUI

/// Single-select folder chips: All mail · Inbox · Sent · Drafts · Junk · Trash · More…
/// Roles the server lacks are hidden (Appendix A.1), and All mail appears only when there
/// are at least two folders for it to merge.
///
/// All mail leads, because it is the selection the list opens on: the chip standing for what
/// is on screen should be the first one read, not one found by scrolling past five others.
struct MailFolderChipBar: View {
    let roles: [MailFolderRole: String]
    let others: [String]
    let showsAllMail: Bool
    let selected: MailFolderSelection
    let onSelect: (MailFolderSelection) -> Void

    /// One chip. `nonisolated` so the synthesized `Hashable` conformance is too — the enclosing
    /// `View` is main-actor isolated by default in this module, and a main-actor `==`/`hash`
    /// cannot satisfy a nonisolated protocol requirement.
    nonisolated enum Entry: Hashable {
        case allMail
        /// The role and the name `LIST` actually reported for it — the chip selects the latter,
        /// never `role.imapName`, which is only ever the fallback used to *find* the folder.
        case role(MailFolderRole, folder: String)
        /// The More… menu, with the folders it lists.
        case more([String])
    }

    /// The chips, in the order they are drawn. Kept apart from `body` so the order is something
    /// a test can state, rather than something only a screenshot can.
    nonisolated static func entries(roles: [MailFolderRole: String], others: [String],
                                    showsAllMail: Bool) -> [Entry] {
        var entries: [Entry] = []
        if showsAllMail { entries.append(.allMail) }
        entries += MailFolderRole.allCases.compactMap { role in
            roles[role].map { Entry.role(role, folder: $0) }
        }
        if !others.isEmpty { entries.append(.more(others)) }
        return entries
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: TigerDuckTheme.Spacing.sm) {
                ForEach(Self.entries(roles: roles, others: others, showsAllMail: showsAllMail), id: \.self) { entry in
                    view(for: entry)
                }
            }
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            .padding(.vertical, TigerDuckTheme.Spacing.xs)
        }
    }

    @ViewBuilder
    private func view(for entry: Entry) -> some View {
        switch entry {
        case .allMail:
            Button { onSelect(.allMail) } label: {
                chip(String(localized: "school_mail_folder_all"), isSelected: selected == .allMail)
            }
            .buttonStyle(.plain)
        case .role(let role, let folder):
            Button { onSelect(.real(folder)) } label: {
                chip(role.title, isSelected: selected == .real(folder))
            }
            .buttonStyle(.plain)
        case .more(let folders):
            Menu {
                ForEach(folders, id: \.self) { folder in
                    Button(ModifiedUTF7.decode(folder)) { onSelect(.real(folder)) }
                }
            } label: {
                // All mail is never one of `others` — it is no folder at all — so the
                // "More…" chip is highlighted only for a real folder from that list.
                chip(String(localized: "school_mail_folder_more"),
                     isSelected: selected.realFolder.map(folders.contains) ?? false)
            }
        }
    }

    private func chip(_ title: String, isSelected: Bool) -> some View {
        Text(title)
            .font(.subheadline.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Color.textPrimary : Color.textSecondary)
            .padding(.horizontal, TigerDuckTheme.Spacing.md)
            .padding(.vertical, TigerDuckTheme.Spacing.xs)
            .glassChip(isSelected: isSelected)
    }
}
#endif
