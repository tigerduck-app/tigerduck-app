#if os(iOS)
import SwiftUI
import UIKit

/// The sender, date, subject and recipients above the mail.
struct MailMessageHeader: View {
    let summary: MailSummary

    var body: some View {
        let sender = Self.senderLines(name: summary.fromName, address: summary.fromAddress)
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: TigerDuckTheme.Spacing.sm) {
                Text(sender.primary ?? String(localized: "school_mail_no_sender"))
                    .font(TigerDuckTheme.Typography.headline)
                    .foregroundStyle(.tint)
                if summary.isExternal {
                    Text(String(localized: "school_mail_external_badge"))
                        .font(TigerDuckTheme.Typography.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.18), in: Capsule())
                        .foregroundStyle(Color.orange)
                }
                Spacer(minLength: 0)
                if let date = summary.date {
                    Text(MailDateFormatter.detailString(for: date))
                        .font(TigerDuckTheme.Typography.caption)
                        .foregroundStyle(Color.textSecondary)
                }
            }
            if let address = sender.secondary {
                Text(address)
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .textSelection(.enabled)
            }
            Text(summary.subject?.mailNonEmpty ?? String(localized: "school_mail_no_subject"))
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.textPrimary)
            let own = MailAccountManager.shared.address
            let to = MailRecipient.parse(summary.to, ownAddress: own)
            let cc = MailRecipient.parse(summary.cc, ownAddress: own)
            if !to.isEmpty {
                MailRecipientRow(label: Self.fieldLabel("school_mail_details_to"), recipients: to)
            }
            if !cc.isEmpty {
                MailRecipientRow(label: Self.fieldLabel("school_mail_details_cc"), recipients: cc)
            }
        }
    }

    nonisolated static func senderLines(name: String?, address: String?) -> (primary: String?, secondary: String?) {
        let name = name?.mailNonEmpty
        let address = address?.mailNonEmpty
        guard let name else { return (address, nil) }
        return (name, address)
    }

    static func fieldLabel(_ key: String.LocalizationValue) -> String {
        String(format: String(localized: key), "").trimmingCharacters(in: .whitespaces)
    }
}

/// The warnings, the blocked-images offer, the parse failure and the last action's error.
struct MailMessageBanners: View {
    let viewModel: MailMessageViewModel

    var body: some View {
        ForEach(Array(viewModel.warnings.enumerated()), id: \.offset) { _, warning in
            MailWarningBanner(message: Self.text(for: warning))
        }
        if let blocked = viewModel.sanitized?.blockedRemoteImages, blocked > 0, viewModel.mode == .formatted {
            MailWarningBanner(
                message: String(localized: "school_mail_remote_images_blocked"),
                systemImage: "photo",
                actionTitle: String(localized: "school_mail_load_images"),
                action: { Task { await viewModel.loadImages() } }
            )
        }
        if viewModel.parseFailed {
            MailWarningBanner(message: String(localized: "school_mail_parse_failed"), systemImage: "doc.text.magnifyingglass")
        }
        if let error = viewModel.actionError {
            MailWarningBanner(message: error, systemImage: "xmark.octagon.fill")
        }
    }

    static func text(for warning: MailWarning) -> String {
        switch warning {
        case .externalSender(let address): appending(address, to: "school_mail_warning_external")
        case .displayNameMismatch(let address): appending(address, to: "school_mail_warning_display_name")
        case .passwordBait: String(localized: "school_mail_warning_password")
        case .riskyAttachment(let filename, _): String(format: String(localized: "school_mail_warning_attachment"), filename)
        case .mistypedRecipient: String(localized: "school_mail_bounce_warning")
        }
    }

    private static func appending(_ address: String, to key: String.LocalizationValue) -> String {
        let title = String(localized: key)
        guard let address = address.mailNonEmpty else { return title }
        return "\(title) \(address)"
    }
}

/// The mail in the view mode picked: formatted, plain text or source.
struct MailMessageContentView: View {
    let viewModel: MailMessageViewModel
    @Binding var webHeight: CGFloat
    @Binding var webLoaded: Bool
    @Binding var pendingLinkTarget: MailLinkTarget?

    var body: some View {
        if viewModel.detail == nil {
            switch viewModel.loadState {
            case .failed(let message):
                MailWarningBanner(message: message, systemImage: "exclamationmark.triangle",
                                  actionTitle: String(localized: "action_retry"),
                                  action: { Task { await viewModel.load() } })
            default:
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 60)
            }
        } else {
            switch viewModel.mode {
            case .formatted:
                if let linked = viewModel.linkedDocument, let html = viewModel.formattedHTML {
                    MailHTMLView(
                        html: html,
                        linkCount: linked.links.count,
                        inlineImages: viewModel.detail?.inlineImages ?? [:],
                        allowRemoteImages: viewModel.allowRemoteImages,
                        theme: viewModel.htmlTheme,
                        contentHeight: $webHeight,
                        onLinkTap: { index in
                            if let target = viewModel.linkTarget(forIndex: index) { pendingLinkTarget = target }
                        },
                        onLoadedChange: { webLoaded = $0 }
                    )
                    .frame(height: webHeight)
                    .clipShape(RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.md))
                    if !webLoaded {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 60)
                    }
                } else {
                    plainBody
                }
            case .plain:
                plainBody
            case .source:
                source
            }
        }
    }

    @ViewBuilder
    private var source: some View {
        if let source = viewModel.source {
            VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
                Button(String(localized: "school_mail_copy_all")) { UIPasteboard.general.string = source }
                    .font(.caption.weight(.semibold))
                MailSourceTextView(text: source)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        } else if viewModel.sourceLoadFailed {
            MailWarningBanner(
                message: String(localized: "school_mail_source_failed"),
                systemImage: "exclamationmark.triangle",
                actionTitle: String(localized: "action_retry"),
                action: { Task { await viewModel.loadSource() } }
            )
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    private var plainBody: some View {
        Text(viewModel.linkedPlainText)
            .font(TigerDuckTheme.Typography.body)
            .foregroundStyle(Color.textPrimary)
            .textSelection(.enabled)
    }
}
#endif
