#if os(iOS)
import SwiftUI

nonisolated struct MailRecipient: Hashable, Sendable {
    var name: String?
    var address: String?
    var raw: String
    var isSelf: Bool

    static let unhyphenatedLanguage = Locale.Language(identifier: "zh-Hant")

    var displayText: String {
        guard let address else { return raw }
        guard let name else { return address }
        return "\(name) <\(address)>"
    }

    static func parse(_ list: [String]?, ownAddress: String?) -> [MailRecipient] {
        let own = ownAddress?.lowercased()
        return (list ?? []).compactMap { entry in
            guard let raw = entry.mailNonEmpty?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            let parsed = MailAddress.parseList(raw).first
            let address = parsed?.address.mailNonEmpty
            return MailRecipient(name: parsed?.name?.mailNonEmpty, address: address, raw: raw,
                                 isSelf: own != nil && address?.lowercased() == own)
        }
    /// Each entry of a `MailSummary.to`/`cc` list — `"Name" <mailbox@host>` or `mailbox@host` —
    /// as a recipient. Blank entries are dropped. `ownAddress` is compared case-insensitively:
    /// Mail2000 writes addresses lowercase, a sender may not.
    }
}

struct MailRecipientRow: View {
    let label: String
    let recipients: [MailRecipient]
    @State private var isExpanded = false

    private var isCollapsible: Bool { recipients.count > 1 }
    private var shown: [MailRecipient] { isExpanded || !isCollapsible ? recipients : Array(recipients.prefix(1)) }
    private var hiddenCount: Int { recipients.count - shown.count }

    var body: some View {
        let row = HStack(alignment: .firstTextBaseline, spacing: TigerDuckTheme.Spacing.xs) {
            Text(label)
            line
                .fixedSize(horizontal: false, vertical: true)
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
        .padding(.vertical, isCollapsible ? 14 : 0)
        if isCollapsible {
            row.scrollSafeTapAction { withAnimation(.snappy) { isExpanded.toggle() } }
        } else {
            row.accessibilityElement(children: .combine)
        }
    }

    private var line: Text {
        var text = Text(verbatim: "")
        for (index, recipient) in shown.enumerated() {
            let part = Text(verbatim: recipient.displayText).typesettingLanguage(MailRecipient.unhyphenatedLanguage)
            let styled = recipient.isSelf ? part.foregroundStyle(.tint) : part
            text = index == 0 ? styled : Text("\(text),\n\(styled)")
        }
        if hiddenCount > 0 { text = Text("\(text)  +\(hiddenCount)") }
        return text
    }
}
#endif
            // On each piece: the modifier on the finished line does not reach inside these.
