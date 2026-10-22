#if os(iOS)
import QuickLook
import SwiftUI
import UIKit

struct MailMessageView: View {
    @State private var viewModel: MailMessageViewModel
    private let session: MailPageSession
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
    @State private var showMoveSheet = false
    @State private var pendingDelete: PendingDelete?
    @State private var compose: MailComposeContext?

    private enum PendingDelete { case toTrash, permanent }

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
        onSeenChanged: @escaping (String, UInt32, Bool) -> Void,
        onRemoved: @escaping (String, UInt32) -> Void,
        onFolderChanged: @escaping (String) -> Void,
        onFolderRolesChanged: @escaping ([MailFolderRole: String]) -> Void
    ) {
        let model = MailMessageViewModel(route: route, session: session, folderRoles: folderRoles)
        model.onSeenChanged = onSeenChanged
        model.onRemoved = onRemoved
        model.onFolderChanged = onFolderChanged
        model.onFolderRolesChanged = onFolderRolesChanged
        _viewModel = State(initialValue: model)
        self.session = session
        self.otherFolders = otherFolders
    }

    var body: some View {
        page
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
        .sheet(item: $shareItem) { item in ShareSheet(url: item.url).presentationDetents([.medium, .large]) }
        .quickLookPreview($previewURL)
        .sheet(isPresented: $showMoveSheet) { moveSheet }
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

    private func confirming(_ kind: PendingDelete) -> Binding<Bool> {
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
            header
            banners
            Divider().background(Color.textSecondary)
            bodyContent
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

    @ViewBuilder
    private var header: some View {
        if let summary = viewModel.summary {
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
                        }
                    )
                    .frame(height: webHeight)
                    .clipShape(RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.md))
                } else {
                    plainBody
                }
            case .plain:
                plainBody
            case .source:
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
        }
    }

    private var plainBody: some View {
        Text(viewModel.linkedPlainText)
            .font(TigerDuckTheme.Typography.body)
            .foregroundStyle(Color.textPrimary)
            .textSelection(.enabled)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { startCompose(.reply) } label: { Label(String(localized: "school_mail_reply"), systemImage: "arrowshape.turn.up.left") }
                Button { startCompose(.replyAll) } label: { Label(String(localized: "school_mail_reply_all"), systemImage: "arrowshape.turn.up.left.2") }
                Button { startCompose(.forward) } label: { Label(String(localized: "school_mail_forward"), systemImage: "arrowshape.turn.up.right") }
            } label: {
                Image(systemName: "arrowshape.turn.up.left")
                    .accessibilityLabel(String(localized: "school_mail_reply_menu"))
            }
            .disabled(viewModel.detail == nil)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Section {
                    Picker(String(localized: "school_mail_view_mode"), selection: $viewModel.mode) {
                        ForEach(viewModel.availableModes) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                }
                if viewModel.offersLightMode {
                    Section {
                        Toggle(isOn: $viewModel.viewsInLightMode) {
                            Label(String(localized: "school_mail_view_light_mode"), systemImage: "sun.max")
                        }
                    }
                }
                Section {
                    Button { Task { await viewModel.toggleSeen() } } label: {
                        let seen = viewModel.detail?.summary.isSeen ?? true
                        Label(seen ? String(localized: "school_mail_mark_unread") : String(localized: "school_mail_mark_read"),
                              systemImage: seen ? "envelope.badge" : "envelope.open")
                    }
                    Button { showMoveSheet = true } label: {
                        Label(String(localized: "school_mail_move_to"), systemImage: "folder")
                    }
                    .disabled(viewModel.isMoving)
                }
                Section {
                    Button(role: .destructive) {
                        Task {
                            let isPermanent = await viewModel.prepareDelete()
                            pendingDelete = isPermanent ? .permanent : .toTrash
                        }
                    } label: {
                        Label(String(localized: "school_mail_delete"), systemImage: "trash")
                    }
                    .disabled(viewModel.isMoving)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .accessibilityLabel(String(localized: "school_mail_message_actions"))
            }
        }
    }

    private var moveSheet: some View {
        NavigationStack {
            List {
                ForEach(MailFolderRole.allCases.filter {
                    viewModel.folderRoles[$0] != nil && viewModel.folderRoles[$0] != viewModel.route.folder
                }, id: \.self) { role in
                    Button(role.title) { move(to: viewModel.folderRoles[role]!) }
                        .disabled(viewModel.isMoving)
                }
                ForEach(otherFolders.filter { $0 != viewModel.route.folder }, id: \.self) { folder in
                    Button(ModifiedUTF7.decode(folder)) { move(to: folder) }
                        .disabled(viewModel.isMoving)
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
        } else if appState.browserPreference == .inApp {
            inAppURL = MailFileItem(url: url)
        } else {
            openURL(url)
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
#endif
