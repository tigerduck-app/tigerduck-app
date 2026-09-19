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
    @State private var showDetails = false
    @State private var showMoveSheet = false
    @State private var pendingDelete: PendingDelete?
    @State private var compose: MailComposeContext?

    /// Which of the two delete confirmations the Delete button raised. One optional backs both
    /// dialogs, so exactly one of them can ever be up: deleting in Trash asks whether to destroy
    /// the mail for good, and deleting anywhere else asks before moving it to Trash — a delete
    /// never happens on a single tap either way.
    private enum PendingDelete { case toTrash, permanent }

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
        .sheet(item: $shareItem) { item in MailShareSheet(url: item.url) }
        .quickLookPreview($previewURL)
        .sheet(isPresented: $showMoveSheet) { moveSheet }
        .sheet(item: $compose) { context in
            MailComposeView(context: context, session: session, folderRoles: viewModel.folderRoles,
                            onFolderRolesChanged: { viewModel.adoptFolderRoles($0) })
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

    // MARK: Sections

    /// `MailSourceTextView` scrolls itself — that is the whole point of it, since nothing
    /// else can show a multi-megabyte document without laying all of it out. So when the
    /// source is on screen the page is a plain `VStack` and the text view takes the height
    /// that is left, rather than a scroll view nested inside another one. Every other mode
    /// keeps the scrolling page it has always had.
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
                MailAttachmentList(parts: attachments, isRisky: viewModel.isRisky, onOpen: open, onShare: share)
            }
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .padding(.top, TigerDuckTheme.Spacing.xl)
        .padding(.bottom, showsSource ? TigerDuckTheme.Spacing.lg : TigerDuckTheme.Spacing.xxl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Drawn from `viewModel.summary`, which the folder's cached page supplies while the body is
    /// still being fetched — one header view, shown the moment anything is known about the mail
    /// rather than only once the whole message has landed.
    @ViewBuilder
    private var header: some View {
        if let summary = viewModel.summary {
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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { startCompose(.reply) } label: { Label(String(localized: "school_mail_reply"), systemImage: "arrowshape.turn.up.left") }
                Button { startCompose(.replyAll) } label: { Label(String(localized: "school_mail_reply_all"), systemImage: "arrowshape.turn.up.left.2") }
                Button { startCompose(.forward) } label: { Label(String(localized: "school_mail_forward"), systemImage: "arrowshape.turn.up.right") }
            } label: {
                // Labelled, like every other icon-only control in the feature: without this
                // VoiceOver reads the SF Symbol's name, and these two menus are the message
                // screen's only action affordances.
                Image(systemName: "arrowshape.turn.up.left")
                    .accessibilityLabel(String(localized: "school_mail_reply_menu"))
            }
            .disabled(viewModel.detail == nil)
        }
        ToolbarItem(placement: .topBarTrailing) {
            // Three groups, matching Android: the view modes, then the two reversible actions,
            // then Delete on its own — the one entry here that loses mail sits behind a divider
            // of its own rather than a thumb's width below Move to….
            Menu {
                Section {
                    Picker(String(localized: "school_mail_view_mode"), selection: $viewModel.mode) {
                        ForEach(viewModel.availableModes) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                }
                Section {
                    Button { Task { await viewModel.toggleSeen() } } label: {
                        let seen = viewModel.detail?.summary.isSeen ?? true
                        Label(seen ? String(localized: "school_mail_mark_unread") : String(localized: "school_mail_mark_read"),
                              systemImage: seen ? "envelope.badge" : "envelope.open")
                    }
                    // A move or delete is four to five round trips with nothing on screen to say so,
                    // so both affordances (and the move sheet's rows) are disabled for the duration —
                    // a second tap would otherwise COPY the mail again and file it into two folders.
                    Button { showMoveSheet = true } label: {
                        Label(String(localized: "school_mail_move_to"), systemImage: "folder")
                    }
                    .disabled(viewModel.isMoving)
                }
                Section {
                    Button(role: .destructive) {
                        // Asynchronous because an account with no Trash gets one created here,
                        // before the dialog is chosen — `prepareDelete()` explains why that has
                        // to happen on this side of the confirmation rather than after it.
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
                // The view model's map, not a copy captured at init: a folder created on demand
                // since this screen opened belongs in this list.
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

    private func startCompose(_ mode: MailComposeMode) {
        compose = MailComposeContext(
            mode: mode, folder: viewModel.route.folder, uid: viewModel.route.uid, original: viewModel.original,
            attachments: mode == .forward ? viewModel.detail?.attachments ?? [] : []
        )
    }

    /// The second gate on a tapped link's scheme, after `MailLinkTarget.canOpen` decided whether
    /// to offer Open at all. Both, rather than one: this is the function that hands a URL to the
    /// system, and it should be readable as safe without tracing where its argument came from.
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

    /// A sender whose address the header never gave in a usable form carries an empty
    /// `address` (`MailAddress.parseSender`), and a banner must not end in a dangling
    /// space where the address would have been.
    private static func appending(_ address: String, to key: String.LocalizationValue) -> String {
        let title = String(localized: key)
        guard let address = address.mailNonEmpty else { return title }
        return "\(title) \(address)"
    }
}
#endif
