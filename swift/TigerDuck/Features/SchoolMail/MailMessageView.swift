#if os(iOS)
import SwiftUI
import UIKit

struct MailMessageView: View {
    @State private var viewModel: MailMessageViewModel
    private let session: MailPageSession
    private let otherFolders: [String]

    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var webHeight: CGFloat = 1
    @State private var webLoaded = false
    @State private var pendingLinkTarget: MailLinkTarget?
    @State private var previewURL: URL?
    @State private var shareItem: MailFileItem?
    @State private var riskyAttachment: RiskyAttachment?
    @State private var showMoveSheet = false
    @State private var pendingDelete: MailDeleteConfirmation?
    @State private var compose: MailComposeContext?

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
        events: MailboxEvents
    ) {
        _viewModel = State(initialValue: MailMessageViewModel(route: route, session: session, folderRoles: folderRoles, events: events))
        self.session = session
        self.otherFolders = otherFolders
    }

    var body: some View {
        page
        .background(Color.backgroundPrimary)
        .onChange(of: colorScheme, initial: true) { _, scheme in viewModel.appearsLight = scheme == .light }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            MailMessageToolbar(viewModel: viewModel, onCompose: startCompose, onMove: { showMoveSheet = true },
                               onDelete: { pendingDelete = $0 })
        }
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
        .sheet(item: $shareItem) { item in ShareSheet(url: item.url).presentationDetents([.medium, .large]) }
        .filePreview($previewURL)
        .sheet(isPresented: $showMoveSheet) {
            MailMoveSheet(viewModel: viewModel, otherFolders: otherFolders, onMove: move, onCancel: { showMoveSheet = false })
        }
        .sheet(item: $compose) { context in
            MailComposeView(context: context, session: session, folderRoles: viewModel.folderRoles,
                            onFolderRolesChanged: { viewModel.adoptFolderRoles($0) },
                            onSentCopyNotice: { viewModel.reportSentCopyNotice($0) })
        }
        .alert(String(localized: "school_mail_risky_title"), isPresented: Binding(
            get: { riskyAttachment != nil }, set: { if !$0 { riskyAttachment = nil } }), presenting: riskyAttachment
        ) { pending in
            // HTML/SVG must never reach Quick Look, which renders it in-process with WebKit
            // (JavaScript on, remote loads allowed). Whatever the user asked for, the confirm
            // button for those says "share" and shares.
            let forcedToShare = viewModel.isNeverRenderedInApp(pending.part)
            Button((pending.forSharing || forcedToShare)
                ? String(localized: "school_mail_attachment_share") : String(localized: "school_mail_open")) {
                proceedWithRiskyAttachment(pending)
            }
            Button(String(localized: "action_cancel"), role: .cancel) {}
        } message: { pending in
            Text(String(format: String(localized: "school_mail_risky_message"), pending.part.filename ?? ""))
        }
        .confirmationDialog(String(localized: "school_mail_delete_forever_title"),
                            isPresented: confirming(.permanent), titleVisibility: .visible) {
            Button(String(localized: "school_mail_delete"), role: .destructive) {
                Task { if await viewModel.delete() { dismiss() } }
            }
            .disabled(viewModel.isMoving)
        } message: {
            Text(String(localized: "school_mail_delete_forever_message"))
        }
        .confirmationDialog(String(localized: "school_mail_delete_confirm_title"),
                            isPresented: confirming(.toTrash), titleVisibility: .visible) {
            Button(String(localized: "school_mail_delete"), role: .destructive) {
                Task { if await viewModel.delete() { dismiss() } }
            }
            .disabled(viewModel.isMoving)
            Button(String(localized: "action_cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "school_mail_delete_confirm_message"))
        }
    }

    private func confirming(_ kind: MailDeleteConfirmation) -> Binding<Bool> {
        Binding(get: { pendingDelete == kind }, set: { if !$0 { pendingDelete = nil } })
    }

    @ViewBuilder
    private var page: some View {
        if showsSource {
            sections
        } else {
            ScrollView { sections }
        }
    }

    private var showsSource: Bool { viewModel.mode == .source && viewModel.source != nil }

    private var sections: some View {
        VStack(alignment: .leading, spacing: TigerDuckTheme.Spacing.lg) {
            if let summary = viewModel.summary { MailMessageHeader(summary: summary) }
            MailMessageBanners(viewModel: viewModel)
            Divider().background(Color.textSecondary)
            MailMessageContentView(viewModel: viewModel, webHeight: $webHeight, webLoaded: $webLoaded,
                                   pendingLinkTarget: $pendingLinkTarget)
            if !showsSource, let attachments = viewModel.detail?.attachments, !attachments.isEmpty {
                MailAttachmentList(parts: attachments, downloading: viewModel.downloading, isRisky: viewModel.isRisky,
                                   onOpen: open, onShare: share)
            }
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .padding(.top, TigerDuckTheme.Spacing.xl)
        .padding(.bottom, showsSource ? TigerDuckTheme.Spacing.lg : TigerDuckTheme.Spacing.xxl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

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

    /// Resumes whichever action (open or share) the risky confirmation was raised for, except
    /// that an HTML/SVG part always goes to the share sheet, never Quick Look, which renders it
    /// in-process with WebKit (JavaScript on, remote loads allowed).
    private func proceedWithRiskyAttachment(_ pending: RiskyAttachment) {
        let forcedToShare = viewModel.isNeverRenderedInApp(pending.part)
        Task {
            guard let url = await viewModel.prepareAttachment(pending.part) else { return }
            if pending.forSharing || forcedToShare { shareItem = MailFileItem(url: url) } else { previewURL = url }
        }
    }

    private func startCompose(_ mode: MailComposeMode) {
        compose = MailComposeContext(
            mode: mode, folder: viewModel.route.folder, uid: viewModel.route.uid, original: viewModel.original,
            attachments: mode == .forward ? viewModel.detail?.attachments ?? [] : []
        )
    }

    private func openLink(_ href: String) {
        guard MailLinkTarget.isOpenable(href), let url = URL(string: href) else { return }
        if url.scheme?.lowercased() == "mailto" {
            let target = url.absoluteString.dropFirst("mailto:".count).split(separator: "?").first.map(String.init) ?? ""
            compose = MailComposeContext(mode: .new, to: MailAddress.parseList(target.removingPercentEncoding ?? target))
        } else {
            openURL(url)
        }
    }

}
#endif
