#if os(iOS)
import SwiftUI

/// One mail in the list, styled like `BulletinCardView`: unread dot and semibold sender,
/// an "external" pill, paperclip, `HH:mm` today / `M/d` otherwise.
struct MailRowView: View {
    let summary: MailSummary

    @Environment(AppState.self) private var appState

    var body: some View {
        let policy = appState.visualStylePolicy
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
            HStack(alignment: .center, spacing: TigerDuckTheme.Spacing.sm) {
                if !summary.isSeen {
                    Circle().fill(.tint).frame(width: 7, height: 7).accessibilityHidden(true)
                }
                Text(sender)
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
                Spacer(minLength: 0)
                if summary.hasAttachments {
                    // Labelled rather than hidden: it is the only thing in the row that says the
                    // mail has attachments. Unlabelled, VoiceOver read "paperclip" between the
                    // sender and the date. (The unread dot above is hidden instead — the
                    // semibold sender already carries that.)
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
            Text(summary.subject?.mailNonEmpty ?? String(localized: "school_mail_no_subject"))
                .font(TigerDuckTheme.Typography.body)
                .foregroundStyle(summary.isSeen ? Color.textSecondary : Color.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .cardPadding()
        .presetCard(policy: policy)
    }

    private var sender: String {
        summary.fromName?.mailNonEmpty ?? summary.fromAddress?.mailNonEmpty ?? String(localized: "school_mail_no_sender")
    }
}
#endif
