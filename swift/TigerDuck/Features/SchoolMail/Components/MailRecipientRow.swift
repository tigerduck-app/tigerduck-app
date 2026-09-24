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

    /// `Name <address>`, the bare address, or the entry as written when it is not an address.
    var displayText: String {
        guard let address else { return raw }
        guard let name else { return address }
        return "\(name) <\(address)>"
    }

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

/// A "To:" or "Cc:" line of the mail being read: its recipients as text, separated by commas,
/// with the student's own address in the accent colour so "this one is me" reads at a glance.
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
        HStack(alignment: .firstTextBaseline, spacing: TigerDuckTheme.Spacing.xs) {
            Text(label)
            line
                .lineLimit(isExpanded ? nil : 1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isCollapsible {
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .accessibilityHidden(true)
            }
        }
        .font(TigerDuckTheme.Typography.caption)
        .foregroundStyle(Color.textSecondary)
        // The whole line, at the platform's minimum touch height, is what opens it. Fixed padding
        // rather than a centred minimum height: the first line then stays exactly where it was
        // and opening only adds lines below it, instead of the whole block re-centring upwards.
        .padding(.vertical, isCollapsible ? 14 : 0)
        .contentShape(Rectangle())
        .onTapGesture {
            guard isCollapsible else { return }
            withAnimation(.snappy) { isExpanded.toggle() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCollapsible ? .isButton : [])
    }

    /// The shown recipients joined with ", ", then "+N" for the ones collapsed away.
    private var line: Text {
        var text = Text(verbatim: "")
        for (index, recipient) in shown.enumerated() {
            let part = Text(verbatim: recipient.displayText)
            let styled = recipient.isSelf ? part.foregroundStyle(.tint) : part
            text = index == 0 ? styled : Text("\(text), \(styled)")
        }
        if hiddenCount > 0 { text = Text("\(text)  +\(hiddenCount)") }
        return text
    }
}
#endif
