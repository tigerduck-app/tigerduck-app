#if os(iOS)
import SwiftUI

/// Single-select folder chips: 收件匣 · 寄件備份 · 草稿 · 廣告信 · 回收筒 · 所有信件 · 更多…
/// Roles the server lacks are hidden (Appendix A.1), and 所有信件 appears only when there
/// are at least two folders for it to merge.
struct MailFolderChipBar: View {
    let roles: [MailFolderRole: String]
    let others: [String]
    let showsAllMail: Bool
    let selected: MailFolderSelection
    let onSelect: (MailFolderSelection) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: TigerDuckTheme.Spacing.sm) {
                ForEach(MailFolderRole.allCases.filter { roles[$0] != nil }, id: \.self) { role in
                    let selection = MailFolderSelection.real(roles[role] ?? role.imapName)
                    Button { onSelect(selection) } label: {
                        chip(role.title, isSelected: selection == selected)
                    }
                    .buttonStyle(.plain)
                }
                if showsAllMail {
                    Button { onSelect(.allMail) } label: {
                        chip(String(localized: "school_mail_folder_all"), isSelected: selected == .allMail)
                    }
                    .buttonStyle(.plain)
                }
                if !others.isEmpty {
                    Menu {
                        ForEach(others, id: \.self) { folder in
                            Button(ModifiedUTF7.decode(folder)) { onSelect(.real(folder)) }
                        }
                    } label: {
                        // 所有信件 is never one of `others` — it is no folder at all — so the
                        // "More…" chip is highlighted only for a real folder from that list.
                        chip(String(localized: "school_mail_folder_more"),
                             isSelected: selected.realFolder.map(others.contains) ?? false)
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
