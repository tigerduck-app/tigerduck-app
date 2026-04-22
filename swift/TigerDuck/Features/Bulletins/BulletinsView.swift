import SwiftUI

/// Top-level bulletin list page. Replaces the legacy SwiftData-backed
/// AnnouncementsView — bulletins now live on the push server and are
/// classified by the server-side LLM pipeline.
///
/// `embedded == true` is used when this view is hosted inside the More
/// tab's NavigationStack, so we don't wrap in our own NavigationStack.
struct BulletinsView: View {
    var embedded: Bool = false

    @Environment(AppState.self) private var appState
    @State private var viewModel = BulletinsViewModel()
    @State private var taxonomy = BulletinTaxonomyStore()
    @State private var showSearch: Bool = false
    @State private var showNotificationSettings: Bool = false

    var body: some View {
        Group {
            if embedded {
                content
            } else {
                NavigationStack { content }
            }
        }
        .task {
            await taxonomy.loadIfNeeded()
            await viewModel.loadIfNeeded()
        }
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(spacing: TigerDuckTheme.Spacing.md) {
                headerRow

                if showSearch {
                    searchBar
                }

                filters

                listOrState
            }
            .padding(.bottom, TigerDuckTheme.Spacing.xxl)
        }
        .background(Color.backgroundPrimary)
        .refreshable { await viewModel.refresh() }
        .navigationDestination(isPresented: $showNotificationSettings) {
            BulletinNotificationSettingsView(taxonomy: taxonomy)
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            Text("公告")
                .font(TigerDuckTheme.Typography.title)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            Button {
                withAnimation(.smoothSpring) {
                    showSearch.toggle()
                    if !showSearch { viewModel.searchText = "" }
                }
            } label: {
                Image(systemName: showSearch ? "xmark" : "magnifyingglass")
                    .foregroundStyle(Color.textSecondary)
            }
            Button {
                showNotificationSettings = true
            } label: {
                Image(systemName: "bell.badge")
                    .foregroundStyle(Color.textSecondary)
            }
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .padding(.top, TigerDuckTheme.Spacing.md)
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.textSecondary)
            TextField("搜尋公告", text: $viewModel.searchText)
                .foregroundStyle(Color.textPrimary)
        }
        .presetSearchBarSurface(policy: appState.visualStylePolicy)
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - Filters

    @ViewBuilder
    private var filters: some View {
        if let tax = taxonomy.state.taxonomy {
            VStack(spacing: TigerDuckTheme.Spacing.sm) {
                BulletinFilterBar(
                    title: "處室",
                    options: tax.orgs.map { (id: $0.rawId, label: $0.label) },
                    selected: viewModel.selectedOrgs,
                    onToggle: { viewModel.toggleOrg($0) }
                )
                BulletinFilterBar(
                    title: "類別",
                    options: tax.tags.map { (id: $0.rawId, label: $0.label) },
                    selected: viewModel.selectedTags,
                    onToggle: { viewModel.toggleTag($0) }
                )
            }
        }
    }

    // MARK: - List body

    @ViewBuilder
    private var listOrState: some View {
        if viewModel.items.isEmpty {
            switch viewModel.loadState {
            case .idle, .loading:
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
            case .failed(let message):
                errorState(message: message)
            case .loaded:
                EmptyStateView(
                    icon: "tray",
                    title: "沒有公告",
                    message: "稍後再回來查看"
                )
                .frame(height: 200)
            }
        } else {
            loadedList
        }
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: TigerDuckTheme.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.orange)
                Text("公告載入失敗")
                    .font(TigerDuckTheme.Typography.headline)
                    .foregroundStyle(Color.textPrimary)
                Text(message)
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            Button("重試") {
                Task { await viewModel.refresh() }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    @ViewBuilder
    private var loadedList: some View {
        if viewModel.filteredItems.isEmpty {
            EmptyStateView(
                icon: "tray",
                title: "沒有公告",
                message: viewModel.hasActiveFilter ? "沒有符合篩選條件的公告" : "稍後再回來查看"
            )
            .frame(height: 200)
        } else {
            LazyVStack(spacing: TigerDuckTheme.Spacing.md) {
                ForEach(viewModel.filteredItems) { bulletin in
                    NavigationLink {
                        BulletinDetailView(bulletin: bulletin, taxonomy: taxonomy)
                    } label: {
                        BulletinCardView(bulletin: bulletin, taxonomy: taxonomy)
                    }
                    .buttonStyle(.plain)
                    .task {
                        await viewModel.loadMoreIfNeeded(triggeredBy: bulletin)
                    }
                }

                if viewModel.isPaginating {
                    ProgressView()
                        .padding(.vertical, TigerDuckTheme.Spacing.md)
                }
            }
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        }
    }
}

private extension BulletinsViewModel {
    var hasActiveFilter: Bool {
        !selectedOrgs.isEmpty || !selectedTags.isEmpty || !searchText.isEmpty
    }
}
