#if os(iOS)
import SwiftUI

///
struct SchoolMailView: View {
    var embedded: Bool = false

    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = MailListViewModel()
    @State private var showLoginSheet = false
    @State private var route: MailMessageRoute?
    @State private var compose: MailComposeContext?
    @State private var isSearchRevealed = false
    @State private var isOnScreen = false
    @FocusState private var isSearchFocused: Bool
    @ScaledMetric(relativeTo: .largeTitle) private var heroIconSize: CGFloat = 36
    @ScaledMetric(relativeTo: .title2) private var composeGlyphLift: CGFloat = 2
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
        .sheet(isPresented: $showLoginSheet) { MailLoginSheet(isPresented: $showLoginSheet) }
        #if DEBUG
        .onChange(of: DevMailServerSettings.shared.generation) { _, _ in
            viewModel.resetForServerChange()
        }
        #endif
    }

    #if DEBUG
    private var isDeveloperServerOverridden: Bool { MailServerConfig.effective.isOverridden }

    /// The page itself has to say when it is not showing school mail.
    ///
    /// Its own row, not a suffix inside `titleBar`: that row's height is matched against Home and
    /// Class table so the three titles sit at the same height, and nothing that could change its
    /// size belongs in it. It reads the whole effective configuration (a host and a domain say
    /// more than "override on") and is absent when the override is off and from Release builds.
    /// Call sites decide whether to show it: in a `List`, a conditional that resolves to nothing
    /// still carries its row modifiers and can leave an empty row and separator in debug builds.
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
            }
            .padding(.bottom, TigerDuckTheme.Spacing.xl)
        }
        .background(Color.backgroundPrimary)
        .scrollDismissesKeyboard(.interactively)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
    }

    ///
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

    private static var headerActionHeight: CGFloat {
        if #available(iOS 26, *) { 36 } else { 40 }
    }
    private static let headerActionWidth: CGFloat = 44
    private static let composeButtonSize: CGFloat = 56

    /// The unread-only filter in a capsule: the backing the toolbar used to supply on iOS 26.
    /// The status dot stays outside it: it reports on the server, it does not act on the mailbox.
    /// The button is `.borderless` because the row is a `List` row now: the default style
    /// there gives the whole row one tap target and drops the tint. `MailFolderChipBar` and
    /// `SyncStatusDot` take `.plain` in the same situation, for the same reason.
    @ViewBuilder
    private var headerActions: some View {
        let row = Button { viewModel.unreadOnly.toggle() } label: {
            headerIcon(viewModel.unreadOnly
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle")
                .symbolRenderingMode(.hierarchical)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(String(localized: "school_mail_unread_only"))
        if #available(iOS 26, *) {
            row.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            row.background(Capsule().fill(Color(uiColor: .secondarySystemFill)))
        }
    }

    /// Search, in the list's own content rather than `.searchable`.
    /// `.searchable` puts its field in the navigation bar, which hides it at rest only under a
    /// large `.navigationTitle`. This page has no navigation title (its title is content, so it
    /// and the buttons sit where Home's and Class table's do), so the field would sit alone in
    /// the bar and hold the header a full bar's height lower than those pages. As a row it
    /// scrolls with everything else and, like the drawer on Announcements, stays hidden until
    /// the list is pulled down past its top (`pullToRevealSearch`).
    private var searchField: some View {
        HStack(spacing: TigerDuckTheme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.textSecondary)
            TextField(String(localized: "school_mail_search_prompt"), text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .focused($isSearchFocused)
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

    /// Floats above the tab bar and steps aside while the search field holds the keyboard, which
    /// would otherwise carry it up over the results.
    private var composeButton: some View {
        Button { compose = MailComposeContext(mode: .new) } label: {
            let glyph = Image(systemName: "square.and.pencil")
                .font(.title2)
                // Optical centring, keep it: `square.and.pencil` draws its rounded square below
                // the centre of its box (the pencil takes the room above). Already centred on x.
                .offset(y: -composeGlyphLift)
                .frame(width: Self.composeButtonSize, height: Self.composeButtonSize)
                .contentShape(.circle)
            if #available(iOS 26, *) {
                glyph.foregroundStyle(.white)
                    .glassEffect(.regular.tint(appState.accentColor).interactive(), in: .circle)
            } else {
                glyph.foregroundStyle(appState.accentColor)
                    .background(.regularMaterial, in: Circle())
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "school_mail_compose"))
        .padding(.trailing, TigerDuckTheme.Spacing.lg)
        .padding(.bottom, TigerDuckTheme.Spacing.sm)
    }

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
            if isSearchRevealed || !viewModel.searchText.isEmpty {
                searchField
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(
                        top: TigerDuckTheme.Spacing.md, leading: 0,
                        bottom: 0, trailing: 0
                    ))
            }
            if account.showsAuthFailedBanner {
                NTUSTReauthErrorBanner(
                    message: String(localized: "school_mail_auth_failed_banner"),
                    onRetry: { showLoginSheet = true },
                    onDismiss: { account.authBannerDismissed = true }
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            if let notice = viewModel.sentCopyNotice {
                MailWarningBanner(
                    message: notice,
                    systemImage: "tray.and.arrow.down",
                    actionTitle: String(localized: "settings_acknowledged"),
                    action: { viewModel.dismissSentCopyNotice() }
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
        .safeAreaInset(edge: .bottom, alignment: .trailing) {
            ZStack {
                if !isSearchFocused { composeButton.transition(.scale.combined(with: .opacity)) }
            }
            .animation(.snappy, value: isSearchFocused)
        }
        .pullToRevealSearch(isRevealed: $isSearchRevealed, isActive: isSearchFocused || !viewModel.searchText.isEmpty)
        .onChange(of: viewModel.searchText) { _, text in
            if text.isEmpty { viewModel.clearSearch() }
        }
        .refreshable { await viewModel.refresh() }
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
        .onAppear {
            isOnScreen = true
            drainDeepLink()
        }
        .onChange(of: appState.pendingDeepLink) { _, _ in drainDeepLink() }
        .sheet(item: $compose, onDismiss: { Task { await viewModel.refresh() } }) { context in
            MailComposeView(context: context, session: viewModel.session, folderRoles: viewModel.folderRoles,
                            onFolderRolesChanged: { roles in viewModel.adoptFolderRoles(roles) },
                            onSentCopyNotice: { notice in viewModel.reportSentCopyNotice(notice) })
        }
        .task {
            await viewModel.refresh()
            viewModel.startPolling()
        }
        .onDisappear {
            isOnScreen = false
            viewModel.stopPolling()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { viewModel.stopPolling() }
            if phase == .active, isOnScreen { viewModel.startPolling(pollFirst: true) }
        }
    }

    /// While the search index downloads, the dot spins and its row counts the mail; before the
    /// pass has a total, the row says it is syncing rather than OK.
    private var statusDot: some View {
        let progress = viewModel.indexProgress
        return SyncStatusDot(
            status: viewModel.serverStatus,
            label: String(localized: "feature_school_mail"),
            icon: "envelope.fill",
            text: progress.map { $0.text() ?? String(localized: "sync_status_syncing") }
                ?? SyncStatusDot.statusText(viewModel.serverStatus),
            isLoading: viewModel.isRefreshing || progress != nil,
            lastSynced: .at(viewModel.syncedAt)
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

    private func drainDeepLink() {
        guard case .schoolMail(let folder, let uid, let uidValidity) = appState.pendingDeepLink, account.isLoggedIn else { return }
        appState.pendingDeepLink = nil
        Task {
            await viewModel.select(.real(folder))
            if let uid { route = MailMessageRoute(folder: folder, uid: uid, uidValidity: uidValidity) }
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
            Button(String(localized: "action_retry")) { Task { await viewModel.refresh() } }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}
#endif
