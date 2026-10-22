import Defaults
import SwiftUI

struct BulletinsView: View {
    var embedded: Bool = false

    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = BulletinsViewModel()
    @Default(.bulletinsSyncedAt) private var bulletinsSyncedAt
    private let taxonomy = BulletinTaxonomyStore.shared
    @State private var readState = BulletinReadStateStore()
    @State private var showNotificationSettings: Bool = false
    @State private var detailingBulletin: BulletinAPI.BulletinSummary?
    @State private var inflightDeepLinkIds: Set<Int> = []
    @State private var unreadOnly: Bool = false
    @State private var searchIsPresented: Bool = false
    @State private var lastBackgroundedAt: Date?

    @ScaledMetric(relativeTo: .largeTitle) private var heroIconSize: CGFloat = 36

    var body: some View {
        Group {
            if embedded {
                content
            } else {
                NavigationStack { content }
            }
        }
        .task {
            async let bulletins: Void = viewModel.loadIfNeeded()
            await taxonomy.loadIfNeeded()
            await bulletins
        }
        .onDisappear { viewModel.pausePrefetch() }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if oldPhase == .background, newPhase == .active,
               let last = lastBackgroundedAt,
               Date().timeIntervalSince(last) > 300 {
                searchIsPresented = false
                viewModel.searchText = ""
            }
            if newPhase == .background {
                lastBackgroundedAt = Date()
            }
            #if os(iOS)
            if newPhase == .active {
                drainPendingBulletinDeepLink()
            }
            #endif
        }
        #if os(iOS)
        .onAppear { drainPendingBulletinDeepLink() }
        .onChange(of: appState.pendingDeepLink) { _, _ in
            drainPendingBulletinDeepLink()
        }
        .onChange(of: viewModel.loadState) { _, newState in
            if case .loaded = newState {
                drainPendingBulletinDeepLink()
            }
        }
        #endif
    }

    #if os(iOS)
    private func drainPendingBulletinDeepLink() {
        guard case .bulletin(let id) = appState.pendingDeepLink else { return }
        guard !inflightDeepLinkIds.contains(id) else { return }
        inflightDeepLinkIds.insert(id)
        Task {
            defer { inflightDeepLinkIds.remove(id) }
            let summary: BulletinAPI.BulletinSummary?
            do {
                summary = try await viewModel.summary(forId: id)
            } catch {
                return
            }
            if case .bulletin(let pendingId) = appState.pendingDeepLink,
               pendingId == id {
                appState.pendingDeepLink = nil
            }
            if let summary {
                detailingBulletin = summary
            }
        }
    }
    #endif

    private var unreadShown: [Int] {
        viewModel.unreadShown(isRead: readState.isRead)
    }

    private var content: some View {
        List {
            if !filtersAvailable.isEmpty {
                Section {
                    filtersBlock
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(
                    top: TigerDuckTheme.Spacing.sm,
                    leading: 0,
                    bottom: TigerDuckTheme.Spacing.sm,
                    trailing: 0
                ))
            }

            bodySection
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.backgroundPrimary)
        .navigationTitle(String(localized: "feature_announcements"))
        .searchable(text: $viewModel.searchText, isPresented: $searchIsPresented, prompt: String(localized: "bulletin_search_prompt"))
        .refreshable { await viewModel.refresh() }
        .toolbar {
            if unreadOnly, !unreadShown.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "bulletin_mark_all_read_action")) {
                        readState.markAllRead(unreadShown)
                    }
                }
            }
            if #available(iOS 26, *) {
                ToolbarItem(placement: .topBarTrailing) {
                    SyncStatusDot(servers: [.backend], lastSynced: .at(bulletinsSyncedAt))
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    SyncStatusDot(servers: [.backend], lastSynced: .at(bulletinsSyncedAt))
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    unreadOnly.toggle()
                } label: {
                    Image(systemName: unreadOnly
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
                        .symbolRenderingMode(.hierarchical)
                }
                .accessibilityLabel(unreadOnly
                    ? String(localized: "bulletin_show_all_action")
                    : String(localized: "bulletin_show_unread_only_action"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showNotificationSettings = true
                } label: {
                    Image(systemName: "bell.badge")
                }
            }
        }
        .navigationDestination(isPresented: $showNotificationSettings) {
            BulletinNotificationSettingsView(taxonomy: taxonomy)
        }
        .navigationDestination(item: $detailingBulletin) { row in
            BulletinDetailView(
                bulletin: row,
                taxonomy: taxonomy,
                readState: readState
            )
        }
    }

    private var filtersAvailable: [BulletinAPI.OrgLabel] {
        taxonomy.state.taxonomy?.orgs ?? []
    }

    @ViewBuilder
    private var filtersBlock: some View {
        if let tax = taxonomy.state.taxonomy {
            VStack(spacing: TigerDuckTheme.Spacing.sm) {
                BulletinFilterBar(
                    title: String(localized: "bulletin_filter_dept"),
                    options: tax.orgs.map { (id: $0.rawId, label: $0.label) },
                    selected: viewModel.selectedOrgs,
                    onToggle: { viewModel.toggleOrg($0) }
                )
                BulletinFilterBar(
                    title: String(localized: "bulletin_filter_tag"),
                    options: tax.tags.map { (id: $0.rawId, label: $0.label) },
                    selected: viewModel.selectedTags,
                    onToggle: { viewModel.toggleTag($0) }
                )
            }
        }
    }

    @ViewBuilder
    private var bodySection: some View {
        if viewModel.items.isEmpty {
            switch viewModel.loadState {
            case .idle, .loading:
                centeredRow {
                    ProgressView().padding(.vertical, 60)
                }
            case .failed(let message):
                centeredRow { errorState(message: message) }
            case .loaded:
                centeredRow {
                    EmptyStateView(
                        icon: "tray",
                        title: String(localized: "bulletin_no_bulletins_title"),
                        message: String(localized: "bulletin_no_bulletins_message")
                    )
                    .frame(height: 200)
                }
            }
        } else if displayedItems.isEmpty {
            centeredRow {
                EmptyStateView(
                    icon: unreadOnly ? "envelope.open" : "tray",
                    title: unreadOnly
                        ? String(localized: "bulletin_no_unread_title")
                        : String(localized: "bulletin_no_bulletins_title"),
                    message: viewModel.hasActiveFilter || unreadOnly
                        ? String(localized: "bulletin_no_match_message")
                        : String(localized: "bulletin_no_bulletins_message")
                )
                .frame(height: 200)
            }
        } else {
            ForEach(displayedItems) { bulletin in
                Button {
                    detailingBulletin = bulletin
                } label: {
                    BulletinCardView(
                        bulletin: bulletin,
                        taxonomy: taxonomy,
                        isRead: readState.isRead(bulletin.id)
                    )
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(
                    top: TigerDuckTheme.Spacing.xs,
                    leading: TigerDuckTheme.Spacing.lg,
                    bottom: TigerDuckTheme.Spacing.xs,
                    trailing: TigerDuckTheme.Spacing.lg
                ))
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button {
                        readState.toggleRead(bulletin.id)
                    } label: {
                        Label(
                            readState.isRead(bulletin.id)
                                ? String(localized: "bulletin_mark_as_unread_action")
                                : String(localized: "bulletin_mark_as_read_action"),
                            systemImage: readState.isRead(bulletin.id)
                                ? "envelope.badge"
                                : "envelope.open"
                        )
                        .labelStyle(.iconOnly)
                    }
                    .tint(appState.accentColor)
                }
                .task {
                    await viewModel.loadMoreIfNeeded(triggeredBy: bulletin)
                }
            }

            if viewModel.isPaginating {
                centeredRow {
                    ProgressView().padding(.vertical, TigerDuckTheme.Spacing.md)
                }
            }
        }
    }

    private var displayedItems: [BulletinAPI.BulletinSummary] {
        if unreadOnly {
            return viewModel.filteredItems.filter { !readState.isRead($0.id) }
        }
        return viewModel.filteredItems
    }

    @ViewBuilder
    private func centeredRow<V: View>(@ViewBuilder content: () -> V) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: TigerDuckTheme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: heroIconSize))
                .foregroundStyle(Color.orange)
            Text(String(localized: "bulletin_load_failed_title"))
                .font(TigerDuckTheme.Typography.headline)
                .foregroundStyle(Color.textPrimary)
            Text(message)
                .font(TigerDuckTheme.Typography.caption)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            Button(String(localized: "action_retry")) {
                Task { await viewModel.refresh() }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

private extension BulletinsViewModel {
    var hasActiveFilter: Bool {
        !selectedOrgs.isEmpty || !selectedTags.isEmpty || !searchText.isEmpty
    }
}
