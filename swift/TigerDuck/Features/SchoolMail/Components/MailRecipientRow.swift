#if os(iOS)
import SwiftUI

/// One recipient of a mail, as the header shows it.
nonisolated struct MailRecipient: Hashable, Sendable {
    /// `nil` when the header gave none.
    var name: String?
    /// `nil` when the entry is not an address this app can read — a group label such as
    /// `undisclosed-recipients:`, a bare `MAILER-DAEMON@` — in which case `raw` is shown as is.
    var address: String?
    var raw: String
    /// This is the signed-in student's own address.
    var isSelf: Bool

    /// Each entry of a `MailSummary.to`/`cc` list — `"Name" <mailbox@host>` or `mailbox@host` —
    /// as a recipient. Blank entries are dropped. `ownAddress` is compared case-insensitively:
    /// Mail2000 writes addresses lowercase, a sender may not.
    static func parse(_ list: [String]?, ownAddress: String?) -> [MailRecipient] {
        let own = ownAddress?.lowercased()
        return (list ?? []).compactMap { entry in
            guard let raw = entry.mailNonEmpty?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            let parsed = MailAddress.parseList(raw).first
            let address = parsed?.address.mailNonEmpty
            return MailRecipient(name: parsed?.name?.mailNonEmpty, address: address, raw: raw,
                                 isSelf: own != nil && address?.lowercased() == own)
        }
    }
}

/// A "To:" or "Cc:" line of recipient bubbles, separated by commas, with the student's own
/// address tinted so "this one is me" reads at a glance.
///
/// More than one recipient collapses to the first and a count, behind its own arrow, so a
/// mail sent to a whole class does not push the message off the screen; each line opens on its
/// own. One recipient is simply shown.
struct MailRecipientRow: View {
    let label: String
    let recipients: [MailRecipient]
    @State private var isExpanded = false

    private var isCollapsible: Bool { recipients.count > 1 }
    private var shown: [MailRecipient] { isExpanded || !isCollapsible ? recipients : Array(recipients.prefix(1)) }
    private var hiddenCount: Int { recipients.count - shown.count }

    var body: some View {
        HStack(alignment: .top, spacing: TigerDuckTheme.Spacing.xs) {
            Text(label)
                .padding(.vertical, 3)
            FlowLayout(spacing: 4, lineSpacing: 6) {
                ForEach(Array(shown.enumerated()), id: \.offset) { index, recipient in
                    HStack(spacing: 0) {
                        bubble(recipient)
                        if index < shown.count - 1 {
                            Text(",").padding(.vertical, 3)
                        }
                    }
                }
                if hiddenCount > 0 {
                    Text("+\(hiddenCount)")
                        .padding(.vertical, 3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isCollapsible {
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .padding(.vertical, 5)
                    .accessibilityHidden(true)
            }
        }
        .font(TigerDuckTheme.Typography.caption)
        .foregroundStyle(Color.textSecondary)
        // The whole line, at the platform's minimum touch height, is what opens it.
        .frame(minHeight: isCollapsible ? 44 : nil)
        .contentShape(Rectangle())
        .onTapGesture {
            guard isCollapsible else { return }
            withAnimation(.snappy) { isExpanded.toggle() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCollapsible ? .isButton : [])
    }

    private func bubble(_ recipient: MailRecipient) -> some View {
        Group {
            if let name = recipient.name, let address = recipient.address {
                Text("\(Text(name).foregroundStyle(Color.textPrimary)) \(address)")
            } else {
                Text(recipient.address ?? recipient.raw)
                    .foregroundStyle(recipient.isSelf ? Color.textPrimary : Color.textSecondary)
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(recipient.isSelf ? AnyShapeStyle(.tint.opacity(0.3)) : AnyShapeStyle(Color.textPrimary.opacity(0.1)),
                    in: Capsule())
        .overlay {
            if recipient.isSelf { Capsule().strokeBorder(.tint.opacity(0.8), lineWidth: 1) }
        }
    }
}
#endif
