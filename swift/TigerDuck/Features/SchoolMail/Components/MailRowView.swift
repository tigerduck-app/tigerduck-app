#if os(iOS)
import SwiftUI

struct MailRowView: View {
    let summary: MailSummary
    let showsFlag: Bool
    let policy: VisualStylePolicy

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let spacing = TigerDuckTheme.Spacing.sm
        let header = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: .center, spacing: spacing))
        VStack(alignment: .leading, spacing: spacing) {
            header {
                HStack(spacing: spacing) { senderLine }
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: spacing) { marks }
            }
            Text(Self.subject(of: summary))
                .font(TigerDuckTheme.Typography.body)
                .foregroundStyle(summary.isSeen ? Color.textSecondary : Color.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .cardPadding()
        .presetCard(policy: policy)
    }

    @ViewBuilder
    private var senderLine: some View {
        if !summary.isSeen {
            Circle().fill(.tint).frame(width: 7, height: 7).accessibilityHidden(true)
        }
        Text(Self.sender(of: summary))
            .font(TigerDuckTheme.Typography.headline)
            .fontWeight(summary.isSeen ? .regular : .semibold)
            .foregroundStyle(Color.textPrimary)
            .lineLimit(1)
        if summary.isExternal {
            Text(String(localized: "school_mail_external_badge"))
                .font(TigerDuckTheme.Typography.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.18), in: Capsule())
                .foregroundStyle(Color.orange)
        }
    }

    @ViewBuilder
    private var marks: some View {
        if showsFlag, summary.isFlagged {
            Image(systemName: "flag.fill")
                .font(TigerDuckTheme.Typography.caption)
                .foregroundStyle(Color.orange)
                .accessibilityLabel(String(localized: "school_mail_flagged"))
        }
        if summary.hasAttachments {
            Image(systemName: "paperclip")
                .font(TigerDuckTheme.Typography.caption)
                .foregroundStyle(Color.textSecondary)
                .accessibilityLabel(String(localized: "school_mail_attachments"))
        }
        if let date = summary.date {
            Text(MailDateFormatter.listString(for: date))
                .font(TigerDuckTheme.Typography.caption)
                .foregroundStyle(Color.textSecondary)
        }
    }

    static func sender(of summary: MailSummary) -> String {
        summary.fromName?.mailNonEmpty ?? summary.fromAddress?.mailNonEmpty ?? String(localized: "school_mail_no_sender")
    }

    static func subject(of summary: MailSummary) -> String {
        summary.subject?.mailNonEmpty ?? String(localized: "school_mail_no_subject")
    }
}
#endif
