#if os(iOS)
import SwiftUI
import UIKit

struct MailFileItem: Identifiable {
    let url: URL
    var id: URL { url }
}

struct MailShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Attachments are never downloaded or opened automatically (§9.5).
struct MailAttachmentList: View {
    let parts: [MailBodyPart]
    let isRisky: (MailBodyPart) -> Bool
    let onOpen: (MailBodyPart) -> Void
    let onShare: (MailBodyPart) -> Void

    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
            Text(String(localized: "school_mail_attachments"))
                .font(TigerDuckTheme.Typography.headline)
                .foregroundStyle(Color.textPrimary)
            ForEach(parts, id: \.section) { part in
                let risky = isRisky(part)
                HStack(spacing: TigerDuckTheme.Spacing.sm) {
                    Image(systemName: risky ? "exclamationmark.triangle.fill" : "doc")
                        .foregroundStyle(risky ? Color.schoolOrange : Color.textSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(part.filename ?? "attachment")
                            .font(TigerDuckTheme.Typography.body)
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(1)
                        if let size = part.size {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                .font(TigerDuckTheme.Typography.caption)
                                .foregroundStyle(Color.textSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Button { onOpen(part) } label: { Image(systemName: "eye") }
                        .accessibilityLabel(String(localized: "school_mail_open"))
                    Button { onShare(part) } label: { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel(String(localized: "school_mail_attachment_share"))
                }
                .buttonStyle(.borderless)
                .cardPadding()
                .presetCard(policy: appState.visualStylePolicy)
            }
        }
    }
}
#endif
