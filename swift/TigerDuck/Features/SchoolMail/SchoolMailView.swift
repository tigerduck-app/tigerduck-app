#if os(iOS)
import SwiftUI

/// The School Mail page (design doc §6.2), modelled on `BulletinsView`.
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
    /// See the compose toolbar button: the glyph's own vertical bias, measured at the default
    /// text size, and scaled here because the symbol itself grows with the text size.
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

    /// The title is deliberately *not* here. Attached to this `Group` — which wraps a
    /// conditional, so it is not itself the scroll view — the navigation bar has nothing to
    /// track, and the page loses the large title and the collapse-on-scroll every other page
    /// has. It goes on the scrolling view of each branch instead, exactly as `BulletinsView`
    /// puts it on its `List`.
    private var content: some View {
        Group {
            if account.isLoggedIn { mailList } else { signedOut }
        }
        .navigationDestination(isPresented: $showGuide) { MailGuideView() }
        .sheet(isPresented: $showLoginSheet) { MailLoginSheet(isPresented: $showLoginSheet) }
    }

    private var signedOut: some View {
        ScrollView {
            VStack(spacing: TigerDuckTheme.Spacing.lg) {
                MailLoginCard()
                Button(String(localized: "school_mail_use_other_app")) { showGuide = true }
                    .font(TigerDuckTheme.Typography.caption)
            }
            .padding(.vertical, TigerDuckTheme.Spacing.xl)
        }
        .background(Color.backgroundPrimary)
        .navigationTitle(String(localized: "feature_school_mail"))
    }

    private var mailList: some View {
        List {
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
        .navigationTitle(String(localized: "feature_school_mail"))
        .searchable(text: $viewModel.searchText, prompt: String(localized: "school_mail_search_prompt"))
        .onSubmit(of: .search) { Task { await viewModel.submitSearch() } }
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
                onFolderChanged: { folder in Task { await viewModel.recoverFromFolderChange(folder) } }
            )
        }
        .onAppear { drainDeepLink() }
        .onChange(of: appState.pendingDeepLink) { _, _ in drainDeepLink() }
        .toolbar {
            if #available(iOS 26, *) {
                ToolbarItem(placement: .topBarTrailing) { statusDot }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .topBarTrailing) { statusDot }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { viewModel.unreadOnly.toggle() } label: {
                    Image(systemName: viewModel.unreadOnly
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
                        .symbolRenderingMode(.hierarchical)
                }
                .accessibilityLabel(String(localized: "school_mail_unread_only"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showGuide = true } label: { Image(systemName: "questionmark.circle") }
                    .accessibilityLabel(String(localized: "school_mail_use_other_app"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { compose = MailComposeContext(mode: .new) } label: {
                    Image(systemName: "square.and.pencil")
                        // Optical centring, not a stray layout tweak — please leave it in.
                        // `square.and.pencil` is drawn with its rounded square 1.5pt *below*
                        // the centre of its own 21pt layout box (the room above belongs to the
                        // pencil), while the two circled glyphs beside it sit dead centre in
                        // theirs. Centred by frame it therefore reads as hanging low next to
                        // them; lifted by that 1.5pt the three line up. Horizontally the square
                        // is already centred, so there is nothing to correct on x.
                        .offset(y: -composeGlyphLift)
                }
                .accessibilityLabel(String(localized: "school_mail_compose"))
            }
        }
        .sheet(item: $compose, onDismiss: { Task { await viewModel.load() } }) { context in
            MailComposeView(context: context, session: viewModel.session, folderRoles: viewModel.folderRoles)
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

    private var statusDot: some View {
        SyncStatusDot(
            status: viewModel.serverStatus,
            label: String(localized: "feature_school_mail"),
            icon: "envelope.fill",
            text: MailConstants.host,
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

    /// The row's own folder decides everything, never the selected chip: opened from 所有信件,
    /// a 寄件備份 mail has to behave exactly as it would had the user opened 寄件備份 itself —
    /// and the chip is not a folder there at all.
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
