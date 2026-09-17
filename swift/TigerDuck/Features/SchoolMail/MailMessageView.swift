#if os(iOS)
import QuickLook
import SwiftUI
import UIKit

struct MailMessageView: View {
    @State private var viewModel: MailMessageViewModel
    private let folderRoles: [MailFolderRole: String]
    private let otherFolders: [String]

    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @State private var webHeight: CGFloat = 1
    @State private var pendingLinkTarget: MailLinkTarget?
    @State private var inAppURL: MailFileItem?
    @State private var previewURL: URL?
    @State private var shareItem: MailFileItem?
    @State private var riskyAttachment: RiskyAttachment?
    @State private var showDetails = false
    @State private var showMoveSheet = false
    @State private var confirmDelete = false

    /// A risky (or HTML/SVG) attachment the user asked to open or share, waiting on the
    /// confirmation dialog — `forSharing` remembers which action to resume once confirmed
    /// (dispatch addition 5: confirm before opening OR saving, and actually do the one asked for).
    private struct RiskyAttachment: Identifiable {
        let part: MailBodyPart
        let forSharing: Bool
        var id: String { part.section }
    }

    init(
        route: MailMessageRoute,
        session: MailPageSession,
        folderRoles: [MailFolderRole: String],
        otherFolders: [String],
        onSeenChanged: @escaping (UInt32, Bool) -> Void,
        onRemoved: @escaping (UInt32) -> Void,
        onFolderChanged: @escaping (String) -> Void
    ) {
        let model = MailMessageViewModel(route: route, session: session, folderRoles: folderRoles)
        model.onSeenChanged = onSeenChanged
        model.onRemoved = onRemoved
        model.onFolderChanged = onFolderChanged
        _viewModel = State(initialValue: model)
        self.folderRoles = folderRoles
        self.otherFolders = otherFolders
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.lg) {
                header
                banners
                Divider().background(Color.textSecondary)
                bodyContent
                if let attachments = viewModel.detail?.attachments, !attachments.isEmpty {
                    MailAttachmentList(parts: attachments, isRisky: viewModel.isRisky, onOpen: open, onShare: share)
                }
            }
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            .padding(.top, TigerDuckTheme.Spacing.xl)
            .padding(.bottom, TigerDuckTheme.Spacing.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.backgroundPrimary)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .environment(\.openURL, OpenURLAction { url in
            pendingLinkTarget = viewModel.linkTarget(forPlainText: url)
            return .handled
        })
        .task { await viewModel.load() }
        .onChange(of: viewModel.mode) { _, mode in
            if mode == .source, viewModel.source == nil { Task { await viewModel.loadSource() } }
        }
        .sheet(item: $pendingLinkTarget) { target in
            MailLinkConfirmation(
                target: target,
                onOpen: { pendingLinkTarget = nil; openLink(target.href) },
                onCancel: { pendingLinkTarget = nil }
            )
        }
        .sheet(item: $inAppURL) { item in InAppBrowserView(url: item.url).ignoresSafeArea() }
        .sheet(item: $shareItem) { item in MailShareSheet(url: item.url) }
        .quickLookPreview($previewURL)
        .sheet(isPresented: $showMoveSheet) { moveSheet }
        .alert(String(localized: "school_mail_source_large_title"), isPresented: Binding(
            get: { viewModel.needsSourceConfirmation }, set: { _ in })
        ) {
            Button(String(localized: "school_mail_open")) { Task { await viewModel.loadSource(confirmed: true) } }
            Button(String(localized: "action_cancel"), role: .cancel) { viewModel.cancelSource() }
        } message: {
            Text(String(format: String(localized: "school_mail_source_large_message"),
                        ByteCountFormatter.string(fromByteCount: Int64(viewModel.detail?.summary.size ?? 0), countStyle: .file)))
        }
        .alert(String(localized: "school_mail_risky_title"), isPresented: Binding(
            get: { riskyAttachment != nil }, set: { if !$0 { riskyAttachment = nil } }), presenting: riskyAttachment
        ) { pending in
            // HTML/SVG must never reach Quick Look (fix round 1, critical 1): whatever the user
            // asked for, the confirm button — and what it does — is always "share" for those.
            let forcedToShare = viewModel.isNeverRenderedInApp(pending.part)
            Button((pending.forSharing || forcedToShare)
                ? String(localized: "school_mail_attachment_share") : String(localized: "school_mail_open")) {
                proceedWithRiskyAttachment(pending)
            }
            Button(String(localized: "action_cancel"), role: .cancel) {}
        } message: { pending in
            Text(String(format: String(localized: "school_mail_risky_message"), pending.part.filename ?? ""))
        }
        .confirmationDialog(String(localized: "school_mail_delete_forever_title"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(String(localized: "school_mail_delete"), role: .destructive) {
                Task { if await viewModel.delete() { dismiss() } }
            }
        } message: {
            Text(String(localized: "school_mail_delete_forever_message"))
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var header: some View {
        if let summary = viewModel.detail?.summary {
            VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
                HStack(alignment: .firstTextBaseline, spacing: TigerDuckTheme.Spacing.sm) {
                    Text(summary.fromName?.mailNonEmpty ?? summary.fromAddress ?? String(localized: "school_mail_no_sender"))
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
                if let address = summary.fromAddress {
                    Text(address)
                        .font(TigerDuckTheme.Typography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .textSelection(.enabled)
                }
                Text(summary.subject?.mailNonEmpty ?? String(localized: "school_mail_no_subject"))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.textPrimary)
                DisclosureGroup(isExpanded: $showDetails) {
                    VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.xs) {
                        if let to = summary.to, !to.isEmpty {
                            Text(String(format: String(localized: "school_mail_details_to"), to.joined(separator: ", ")))
                        }
                        if let cc = summary.cc, !cc.isEmpty {
                            Text(String(format: String(localized: "school_mail_details_cc"), cc.joined(separator: ", ")))
                        }
                    }
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .textSelection(.enabled)
                } label: {
                    Text(String(format: String(localized: "school_mail_details_to"), summary.to?.first ?? ""))
                        .font(TigerDuckTheme.Typography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private var banners: some View {
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

    @ViewBuilder
    private var bodyContent: some View {
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
                if let linked = viewModel.linkedDocument {
                    MailHTMLView(
                        html: linked.html,
                        linkCount: linked.links.count,
                        inlineImages: viewModel.detail?.inlineImages ?? [:],
                        allowRemoteImages: viewModel.allowRemoteImages,
                        contentHeight: $webHeight,
                        onLinkTap: { index in
                            if let target = viewModel.linkTarget(forIndex: index) { pendingLinkTarget = target }
                        }
                    )
                    .frame(height: webHeight)
                    .clipShape(RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.md))
                } else {
                    Text(MailTextLinkifier.attributed(viewModel.plainText))
                        .font(TigerDuckTheme.Typography.body)
                        .foregroundStyle(Color.textPrimary)
                        .textSelection(.enabled)
                }
            case .plain:
                Text(viewModel.plainText)
                    .font(TigerDuckTheme.Typography.body)
                    .foregroundStyle(Color.textPrimary)
                    .textSelection(.enabled)
            case .source:
                if let source = viewModel.source {
                    VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.sm) {
                        Button(String(localized: "school_mail_copy_all")) { UIPasteboard.general.string = source }
                            .font(.caption.weight(.semibold))
                        ScrollView(.horizontal) {
                            Text(source)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Color.textPrimary)
                                .textSelection(.enabled)
                        }
                    }
                } else if viewModel.sourceLoadFailed {
                    MailWarningBanner(
                        message: String(localized: "school_mail_source_failed"),
                        systemImage: "exclamationmark.triangle",
                        actionTitle: String(localized: "action_retry"),
                        action: { Task { await viewModel.loadSource() } }
                    )
                } else if !viewModel.needsSourceConfirmation {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker(String(localized: "school_mail_view_mode"), selection: $viewModel.mode) {
                    ForEach(MailMessageViewModel.ViewMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Button { Task { await viewModel.toggleSeen() } } label: {
                    let seen = viewModel.detail?.summary.isSeen ?? true
                    Label(seen ? String(localized: "school_mail_mark_unread") : String(localized: "school_mail_mark_read"),
                          systemImage: seen ? "envelope.badge" : "envelope.open")
                }
                Button { showMoveSheet = true } label: {
                    Label(String(localized: "school_mail_move_to"), systemImage: "folder")
                }
                Button(role: .destructive) {
                    if viewModel.deleteIsPermanent {
                        confirmDelete = true
                    } else {
                        Task { if await viewModel.delete() { dismiss() } }
                    }
                } label: {
                    Label(String(localized: "school_mail_delete"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private var moveSheet: some View {
        NavigationStack {
            List {
                ForEach(MailFolderRole.allCases.filter { folderRoles[$0] != nil && folderRoles[$0] != viewModel.route.folder }, id: \.self) { role in
                    Button(role.title) { move(to: folderRoles[role]!) }
                }
                ForEach(otherFolders.filter { $0 != viewModel.route.folder }, id: \.self) { folder in
                    Button(ModifiedUTF7.decode(folder)) { move(to: folder) }
                }
            }
            .navigationTitle(String(localized: "school_mail_move_to"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action_cancel")) { showMoveSheet = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Actions

    private func move(to folder: String) {
        showMoveSheet = false
        Task { if await viewModel.move(to: folder) { dismiss() } }
    }

    private func open(_ part: MailBodyPart) {
        if viewModel.isRisky(part) {
            riskyAttachment = RiskyAttachment(part: part, forSharing: false)
            return
        }
        Task { previewURL = await viewModel.prepareAttachment(part) }
    }

    private func share(_ part: MailBodyPart) {
        if viewModel.isRisky(part) {
            riskyAttachment = RiskyAttachment(part: part, forSharing: true)
            return
        }
        Task { if let url = await viewModel.prepareAttachment(part) { shareItem = MailFileItem(url: url) } }
    }

    /// Resumes whichever action (open or share) the risky confirmation was raised for (dispatch
    /// addition 5) — except an HTML/SVG part is always forced to the share sheet regardless of
    /// what was asked, never Quick Look (fix round 1, critical 1).
    private func proceedWithRiskyAttachment(_ pending: RiskyAttachment) {
        let forcedToShare = viewModel.isNeverRenderedInApp(pending.part)
        Task {
            guard let url = await viewModel.prepareAttachment(pending.part) else { return }
            if pending.forSharing || forcedToShare { shareItem = MailFileItem(url: url) } else { previewURL = url }
        }
    }

    private func openLink(_ href: String) {
        guard let url = URL(string: href) else { return }
        if url.scheme?.lowercased() != "mailto", appState.browserPreference == .inApp {
            inAppURL = MailFileItem(url: url)
        } else {
            openURL(url)
        }
    }

    static func text(for warning: MailWarning) -> String {
        switch warning {
        case .externalSender(let address): "\(String(localized: "school_mail_warning_external")) \(address)"
        case .displayNameMismatch(let address): "\(String(localized: "school_mail_warning_display_name")) \(address)"
        case .passwordBait: String(localized: "school_mail_warning_password")
        case .riskyAttachment(let filename, _): String(format: String(localized: "school_mail_warning_attachment"), filename)
        }
    }
}
#endif
