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
    @ScaledMetric(relativeTo: .largeTitle) private var heroIconSize: CGFloat = 36
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
        .navigationTitle(account.isLoggedIn ? viewModel.title : String(localized: "feature_school_mail"))
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
                selected: viewModel.selectedFolder,
                onSelect: { folder in Task { await viewModel.select(folder: folder) } }
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
                onSeenChanged: { uid, seen in viewModel.markSeenLocally(uid: uid, seen: seen) },
                onRemoved: { uid in viewModel.removeLocally(uid: uid) },
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
        let items = viewModel.displayedSummaries
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
            ForEach(items) { summary in
                row(summary)
            }
            if viewModel.isPaginating {
                centered { ProgressView().padding(.vertical, TigerDuckTheme.Spacing.md) }
            }
        }
    }

    private func row(_ summary: MailSummary) -> some View {
        Button {
            route = MailMessageRoute(folder: viewModel.selectedFolder, uid: summary.uid)
        } label: {
            MailRowView(summary: summary)
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(
            top: TigerDuckTheme.Spacing.xs, leading: TigerDuckTheme.Spacing.lg,
            bottom: TigerDuckTheme.Spacing.xs, trailing: TigerDuckTheme.Spacing.lg
        ))
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button { Task { await viewModel.toggleRead(summary) } } label: {
                Label(
                    summary.isSeen ? String(localized: "school_mail_mark_unread") : String(localized: "school_mail_mark_read"),
                    systemImage: summary.isSeen ? "envelope.badge" : "envelope.open"
                )
                .labelStyle(.iconOnly)
            }
            .tint(appState.accentColor)
        }
        .task { await viewModel.loadMoreIfNeeded(after: summary) }
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
            await viewModel.select(folder: folder)
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
