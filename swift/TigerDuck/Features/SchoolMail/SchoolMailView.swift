#if os(iOS)
import SwiftUI

///
struct SchoolMailView: View {
    var embedded: Bool = false

    @Environment(AppEnvironment.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = MailListViewModel()
    @State private var showLoginSheet = false
    @State private var route: MailMessageRoute?
    @State private var compose: MailComposeContext?
    @State private var isSearchRevealed = false
    @State private var isOnScreen = false
    @FocusState private var isSearchFocused: Bool
    private let account = MailAccountManager.shared
    private let sendHold = MailSendHold.shared

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
        .pageMenu(.mail)
        #if DEBUG
        .onChange(of: DevMailServerSettings.shared.revision) { _, _ in
            viewModel.resetForServerChange()
        }
        #endif
    }

    #if DEBUG
    private var isDeveloperServerOverridden: Bool { MailServerConfig.effective.isOverridden }
    #endif

    private var signedOut: some View {
        ScrollView {
            VStack(spacing: TigerDuckTheme.Spacing.lg) {
                titleBar
                #if DEBUG
                if isDeveloperServerOverridden { MailDeveloperServerBanner() }
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

    private var titleBar: some View {
        MailTitleBar(viewModel: viewModel, isLoggedIn: account.isLoggedIn)
    }

    private var mailList: some View {
        List {
            titleBar
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
            #if DEBUG
            if isDeveloperServerOverridden {
                MailDeveloperServerBanner()
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
            }
            #endif
            if isSearchRevealed || !viewModel.searchText.isEmpty {
                MailSearchField(text: $viewModel.searchText, isFocused: $isSearchFocused) {
                    Task { await viewModel.submitSearch() }
                }
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
            MailListRowsSection(viewModel: viewModel, accentColor: app.preferences.accentColor, onOpen: open)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.backgroundPrimary)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .scrollDismissesKeyboard(.immediately)
        .safeAreaInset(edge: .bottom, alignment: .trailing) {
            MailListBottomBar(hold: sendHold, showsCompose: !isSearchFocused, accentColor: app.preferences.accentColor) {
                compose = MailComposeContext(mode: .new)
            }
        }
        .pullToRevealSearch(isRevealed: $isSearchRevealed, isActive: isSearchFocused || !viewModel.searchText.isEmpty)
        .onChange(of: viewModel.searchText) { _, text in
            if text.isEmpty { viewModel.clearSearch() }
        }
        .refreshable { await viewModel.refresh(forcingIndex: true) }
        .navigationDestination(item: $route) { route in
            MailMessageView(
                route: route,
                session: viewModel.session,
                folderRoles: viewModel.folderRoles,
                otherFolders: viewModel.otherFolders,
                events: viewModel.events
            )
            // The browser opens as the link confirmation closes, from the view that showed it.
            .linkRouting()
        }
        .onAppear {
            isOnScreen = true
            drainDeepLink()
        }
        .onChange(of: app.router.pendingDeepLink) { _, _ in drainDeepLink() }
        .sheet(item: $compose, onDismiss: { Task { await viewModel.refresh() } }) { context in
            MailComposeView(context: context, session: viewModel.session, folderRoles: viewModel.folderRoles,
                            events: viewModel.events)
        }
        .onChange(of: sendHold.deliveries) { Task { await viewModel.refresh() } }
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

    private func open(_ row: MailListRow) {
        if row.folder == viewModel.folderRoles[.drafts] {
            compose = MailComposeContext(mode: .draft, folder: row.folder, uid: row.uid)
        } else {
            route = MailMessageRoute(folder: row.folder, uid: row.uid)
        }
    }

    private func drainDeepLink() {
        guard case .schoolMail(let folder, let uid, let uidValidity) = app.router.pendingDeepLink, account.isLoggedIn else { return }
        app.router.pendingDeepLink = nil
        Task {
            await viewModel.select(.real(folder))
            if let uid { route = MailMessageRoute(folder: folder, uid: uid, uidValidity: uidValidity) }
        }
    }

}
#endif
