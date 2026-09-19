#if os(iOS)
import SwiftUI

/// The School Mail page (design doc §6.2).
///
/// The page header follows `HomeView` / `ClassTableView`, not the navigation-bar title
/// `BulletinsView` uses: the title is the first row of the scrolling content, in
/// `Typography.title`, with the status dot and the action buttons on the same row. That is
/// what puts School Mail's title and its buttons at the same height as every other page —
/// a `.navigationTitle` plus `.toolbar` items sits a navigation bar higher and one type
/// size larger, which is the difference users were seeing.
struct SchoolMailView: View {
    var embedded: Bool = false

    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = MailListViewModel()
    @State private var showLoginSheet = false
    @State private var showGuide = false
    @State private var route: MailMessageRoute?
    @State private var compose: MailComposeContext?
    @ScaledMetric(relativeTo: .largeTitle) private var heroIconSize: CGFloat = 36
    /// See the compose button in the header row: the glyph's own vertical bias, measured at
    /// the default text size, and scaled here because the symbol itself grows with the text
    /// size.
    @ScaledMetric(relativeTo: .body) private var composeGlyphLift: CGFloat = 1.5
    private let account = MailAccountManager.shared

    var body: some View {
        Group {
            if embedded {
                content
            } else {
                NavigationStack { content }
            }
        }
    }

    private var content: some View {
        Group {
            if account.isLoggedIn { mailList } else { signedOut }
        }
        .navigationDestination(isPresented: $showGuide) { MailGuideView() }
        .sheet(isPresented: $showLoginSheet) { MailLoginSheet(isPresented: $showLoginSheet) }
        #if DEBUG
        // Reading `generation` here is also what registers this page as an observer of it, so
        // the banner below re-evaluates the moment the override changes rather than waiting
        // for the next unrelated redraw.
        .onChange(of: DevMailServerSettings.shared.generation) { _, _ in
            viewModel.resetForServerChange()
        }
        #endif
    }

    #if DEBUG
    private var isDeveloperServerOverridden: Bool { MailServerConfig.effective.isOverridden }

    /// Requirement 5: the page itself has to say when it is not showing school mail.
    ///
    /// Its own row, deliberately not a suffix inside `titleBar`: that row's height is measured
    /// against Home and Class table so the three pages put their titles at the same height, and
    /// nothing that could change its intrinsic size belongs in it. This sits underneath, reads
    /// the whole effective configuration (a host and a domain say more than "override on"), and
    /// is absent entirely when the override is off — and from Release builds, where neither the
    /// banner nor the type it reads exists.
    ///
    /// Whether to show it is decided by the call sites rather than in here: inside a `List`, a
    /// conditional that resolves to nothing still carries the row modifiers applied to it and
    /// can leave an empty row, with a separator, in the mail list of every ordinary debug
    /// build.
    private var developerServerBanner: some View {
        let config = MailServerConfig.effective
        return Group {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Developer server override — not your school mail")
                        .font(TigerDuckTheme.Typography.caption)
                        .foregroundStyle(Color.textPrimary)
                    Text("@\(config.addressDomain) · IMAP \(config.imapHost):\(config.imapPort) · SMTP \(config.smtpHost):\(config.smtpPort)")
                        .font(TigerDuckTheme.Typography.caption)
                        .foregroundStyle(Color.textSecondary)
                }
            } icon: {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .foregroundStyle(Color.orange)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(TigerDuckTheme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: TigerDuckTheme.Spacing.md, style: .continuous)
                    .fill(Color.orange.opacity(0.12))
            )
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            .padding(.top, TigerDuckTheme.Spacing.sm)
        }
    }
    #endif

    private var signedOut: some View {
        ScrollView {
            VStack(spacing: TigerDuckTheme.Spacing.lg) {
                titleBar
                #if DEBUG
                if isDeveloperServerOverridden { developerServerBanner }
                #endif
                MailLoginCard()
                    .padding(.top, TigerDuckTheme.Spacing.sm)
                Button(String(localized: "school_mail_use_other_app")) { showGuide = true }
                    .font(TigerDuckTheme.Typography.caption)
            }
            .padding(.bottom, TigerDuckTheme.Spacing.xl)
        }
        .background(Color.backgroundPrimary)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
    }

    /// The page header, in the shape `HomeView` and `ClassTableView` use: title text as
    /// scroll content, everything else trailing on the same row.
    ///
    /// Signed out the row is the title alone — the same rule `ClassTableView` applies when
    /// the page has nothing to act on yet. The row keeps `headerActionHeight` either way, so
    /// the title does not hop when the buttons arrive on sign-in.
    private var titleBar: some View {
        HStack {
            Text(String(localized: "feature_school_mail"))
                .font(TigerDuckTheme.Typography.title)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            if account.isLoggedIn {
                HStack(spacing: TigerDuckTheme.Spacing.lg) {
                    statusDot
                    headerActions
                }
            }
        }
        .frame(minHeight: Self.headerActionHeight)
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .padding(.top, TigerDuckTheme.Spacing.md)
    }

    /// Matches `ClassTableView.headerActionHeight`, and for the same reason: the header row
    /// is as tall as its controls, so two pages whose controls differ in height put their
    /// titles at different heights. The glyphs inside stay the size they were in the toolbar
    /// — only the box around them is pinned.
    private static var headerActionHeight: CGFloat {
        if #available(iOS 26, *) { 36 } else { 40 }
    }
    /// Wider than tall, so three adjacent cells read as one capsule rather than three circles.
    private static let headerActionWidth: CGFloat = 44

    /// Unread-only filter, guide and compose, sharing one capsule — the backing the toolbar
    /// used to supply on iOS 26. The status dot stays outside it: it reports on the server,
    /// it does not act on the mailbox.
    ///
    /// Each button is `.borderless` because the row is a `List` row now: the default style
    /// there gives the whole row one tap target and drops the tint, so three `.automatic`
    /// buttons would render untinted and fire as one. `MailFolderChipBar` and `SyncStatusDot`
    /// take `.plain` in the same situation, for the same reason.
    @ViewBuilder
    private var headerActions: some View {
        let row = HStack(spacing: 0) {
            Button { viewModel.unreadOnly.toggle() } label: {
                headerIcon(viewModel.unreadOnly
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle")
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(String(localized: "school_mail_unread_only"))
            Button { showGuide = true } label: {
                headerIcon("questionmark.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(String(localized: "school_mail_use_other_app"))
            Button { compose = MailComposeContext(mode: .new) } label: {
                headerIcon("square.and.pencil")
                    // Optical centring, not a stray layout tweak — please leave it in.
                    // `square.and.pencil` is drawn with its rounded square 1.5pt *below*
                    // the centre of its own 21pt layout box (the room above belongs to the
                    // pencil), while the two circled glyphs beside it sit dead centre in
                    // theirs. Centred by frame it therefore reads as hanging low next to
                    // them; lifted by that 1.5pt the three line up. Horizontally the square
                    // is already centred, so there is nothing to correct on x.
                    .offset(y: -composeGlyphLift)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(String(localized: "school_mail_compose"))
        }
        if #available(iOS 26, *) {
            row.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            // Below 26 nothing supplies a backing, and three bare glyphs over the list read
            // as part of it rather than as controls acting on it. `.secondarySystemFill` is
            // what `.bordered` fills with, which is what `ClassTableView` matches there too.
            row.background(Capsule().fill(Color(uiColor: .secondarySystemFill)))
        }
    }

    /// Search, in the list's own content rather than `.searchable`.
    ///
    /// `.searchable` puts its field in the navigation bar, and the bar only hides that field
    /// at rest when the page has a large `.navigationTitle` to collapse it under. This page
    /// deliberately has no navigation title — the title is content now, so that it and the
    /// buttons sit where Home's and Class table's do — which left the search field alone in
    /// the bar, holding the header a full bar's height lower than those two pages: the very
    /// mismatch this page was reported for. As a row it scrolls with everything else.
    private var searchField: some View {
        HStack(spacing: TigerDuckTheme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.textSecondary)
            TextField(String(localized: "school_mail_search_prompt"), text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit { Task { await viewModel.submitSearch() } }
            if !viewModel.searchText.isEmpty {
                Button { viewModel.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "action_clear_text"))
            }
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.md)
        .padding(.vertical, TigerDuckTheme.Spacing.sm)
        .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }

    /// `contentShape` is explicit because the glyph is smaller than its cell: without it the
    /// tappable area is the symbol's own bounds, not the padding that shapes the capsule.
    private func headerIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.body)
            .frame(width: Self.headerActionWidth, height: Self.headerActionHeight)
            .contentShape(.rect)
    }

    private var mailList: some View {
        List {
            titleBar
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
            #if DEBUG
            if isDeveloperServerOverridden {
                developerServerBanner
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
            }
            #endif
            searchField
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(
                    top: TigerDuckTheme.Spacing.md, leading: 0,
                    bottom: 0, trailing: 0
                ))
            if account.authFailed {
                NTUSTReauthErrorBanner(
                    message: String(localized: "school_mail_auth_failed_banner"),
                    onRetry: { showLoginSheet = true },
                    onDismiss: {}
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            MailFolderChipBar(
                roles: viewModel.folderRoles,
                others: viewModel.otherFolders,
                showsAllMail: viewModel.showsAllMailChip,
                selected: viewModel.selection,
                onSelect: { selection in Task { await viewModel.select(selection) } }
            )
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
            if viewModel.searchUsedLocalFallback {
                Label(String(localized: "school_mail_search_local_only"), systemImage: "info.circle")
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            rows
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.backgroundPrimary)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .scrollDismissesKeyboard(.immediately)
        .onChange(of: viewModel.searchText) { _, text in
            if text.isEmpty { viewModel.clearSearch() }
        }
        .refreshable { await viewModel.load() }
        .navigationDestination(item: $route) { route in
            MailMessageView(
                route: route,
                session: viewModel.session,
                folderRoles: viewModel.folderRoles,
                otherFolders: viewModel.otherFolders,
                onSeenChanged: { folder, uid, seen in viewModel.markSeenLocally(folder: folder, uid: uid, seen: seen) },
                onRemoved: { folder, uid in viewModel.removeLocally(folder: folder, uid: uid) },
                onFolderChanged: { folder in Task { await viewModel.recoverFromFolderChange(folder) } },
                onFolderRolesChanged: { roles in viewModel.adoptFolderRoles(roles) }
            )
        }
        .onAppear { drainDeepLink() }
        .onChange(of: appState.pendingDeepLink) { _, _ in drainDeepLink() }
        .sheet(item: $compose, onDismiss: { Task { await viewModel.load() } }) { context in
            MailComposeView(context: context, session: viewModel.session, folderRoles: viewModel.folderRoles,
                            onFolderRolesChanged: { roles in viewModel.adoptFolderRoles(roles) })
        }
        .task {
            await viewModel.load()
            viewModel.startPolling()
        }
        .onDisappear { viewModel.stopPolling() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { viewModel.stopPolling() }
            if phase == .active { viewModel.startPolling() }
        }
    }

    /// The row reports the mail server's state, in the same three words every other source in
    /// this popover uses — not `MailConstants.host`, which is a constant and says the same
    /// thing whether the server is answering or down. The library page keeps its own wording
    /// because signed-in / not-signed-in genuinely is a different distinction; a mail server
    /// has no equivalent.
    private var statusDot: some View {
        SyncStatusDot(
            status: viewModel.serverStatus,
            label: String(localized: "feature_school_mail"),
            icon: "envelope.fill",
            text: SyncStatusDot.statusText(viewModel.serverStatus),
            isLoading: viewModel.isRefreshing
        )
    }

    @ViewBuilder
    private var rows: some View {
        let items = viewModel.displayedRows
        if items.isEmpty {
            switch viewModel.loadState {
            case .idle, .loading:
                centered { ProgressView().padding(.vertical, 60) }
            case .failed(let message):
                centered { failure(message) }
            case .loaded:
                centered {
                    EmptyStateView(
                        icon: viewModel.unreadOnly ? "envelope.open" : "tray",
                        title: String(localized: "school_mail_empty_title"),
                        message: String(localized: "school_mail_empty_message")
                    )
                    .frame(height: 200)
                }
            }
        } else {
            ForEach(items) { item in
                row(item)
            }
            if viewModel.isPaginating {
                centered { ProgressView().padding(.vertical, TigerDuckTheme.Spacing.md) }
            }
        }
    }

    /// The row's own folder decides everything, never the selected chip: opened from All mail,
    /// a Sent mail has to behave exactly as it would had the user opened Sent itself — and the
    /// chip is not a folder there at all.
    private func row(_ row: MailListRow) -> some View {
        Button {
            if row.folder == viewModel.folderRoles[.drafts] {
                compose = MailComposeContext(mode: .draft, folder: row.folder, uid: row.uid)
            } else {
                route = MailMessageRoute(folder: row.folder, uid: row.uid)
            }
        } label: {
            MailRowView(summary: row.summary)
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(
            top: TigerDuckTheme.Spacing.xs, leading: TigerDuckTheme.Spacing.lg,
            bottom: TigerDuckTheme.Spacing.xs, trailing: TigerDuckTheme.Spacing.lg
        ))
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button { Task { await viewModel.toggleRead(row) } } label: {
                Label(
                    row.summary.isSeen ? String(localized: "school_mail_mark_unread") : String(localized: "school_mail_mark_read"),
                    systemImage: row.summary.isSeen ? "envelope.badge" : "envelope.open"
                )
                .labelStyle(.iconOnly)
            }
            .tint(appState.accentColor)
        }
        .task { await viewModel.loadMoreIfNeeded(after: row) }
    }

    private func centered<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
    }

    /// A tapped mail notification (Task 13): switch folder, then open the message.
    private func drainDeepLink() {
        guard case .schoolMail(let folder, let uid) = appState.pendingDeepLink, account.isLoggedIn else { return }
        appState.pendingDeepLink = nil
        Task {
            // A notification names a real folder (only INBOX ever posts one), so the list goes
            // to that folder itself rather than to the merged view.
            await viewModel.select(.real(folder))
            if let uid { route = MailMessageRoute(folder: folder, uid: uid) }
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: TigerDuckTheme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: heroIconSize))
                .foregroundStyle(Color.orange)
            Text(String(localized: "school_mail_load_failed_title"))
                .font(TigerDuckTheme.Typography.headline)
                .foregroundStyle(Color.textPrimary)
            Text(message)
                .font(TigerDuckTheme.Typography.caption)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            Button(String(localized: "action_retry")) { Task { await viewModel.load() } }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}
#endif
