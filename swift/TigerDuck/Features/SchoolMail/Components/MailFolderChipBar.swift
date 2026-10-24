#if os(iOS)
import SwiftUI

struct MailFolderChipBar: View {
    let roles: [MailFolderRole: String]
    let others: [String]
    let showsAllMail: Bool
    let selected: MailFolderSelection
    let onSelect: (MailFolderSelection) -> Void

    nonisolated enum Entry: Hashable {
        case allMail
        case role(MailFolderRole, folder: String)
        case more([String])
    }

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
                chip(String(localized: "school_mail_folder_more"),
                     isSelected: selected.realFolder.map(folders.contains) ?? false)
            }
        }
    }

    private func chip(_ title: String, isSelected: Bool) -> some View {
        Text(title)
            .font(.subheadline.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Color.white : Color.textSecondary)
            .padding(.horizontal, TigerDuckTheme.Spacing.md)
            .padding(.vertical, TigerDuckTheme.Spacing.xs)
            .glassChip(isSelected: isSelected)
    }
}
#endif
