#if os(iOS)
import SwiftUI

/// Single-select folder chips: 收件匣 · 寄件備份 · 草稿 · 廣告信 · 回收筒 · 更多…
/// Roles the server lacks are hidden (Appendix A.1).
struct MailFolderChipBar: View {
    let roles: [MailFolderRole: String]
    let others: [String]
    let selected: String
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: TigerDuckTheme.Spacing.sm) {
                ForEach(MailFolderRole.allCases.filter { roles[$0] != nil }, id: \.self) { role in
                    let folder = roles[role] ?? role.imapName
                    Button { onSelect(folder) } label: {
                        chip(role.title, isSelected: folder == selected)
                    }
                    .buttonStyle(.plain)
                }
                if !others.isEmpty {
                    Menu {
                        ForEach(others, id: \.self) { folder in
                            Button(ModifiedUTF7.decode(folder)) { onSelect(folder) }
                        }
                    } label: {
                        chip(String(localized: "school_mail_folder_more"), isSelected: others.contains(selected))
                    }
                }
            }
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            .padding(.vertical, TigerDuckTheme.Spacing.xs)
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
