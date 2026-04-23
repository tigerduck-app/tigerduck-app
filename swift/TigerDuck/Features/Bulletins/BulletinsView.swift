import SwiftUI

/// Top-level bulletin list page. Bulletins live on the push server and are
/// classified by the server-side LLM pipeline (replaces the legacy
/// SwiftData-backed AnnouncementsView).
///
/// Layout uses a `List` so per-row swipe actions and the iOS 26 native
/// search field (reveal-on-scroll, Liquid Glass) work without any custom
/// gesture wiring. `embedded == true` skips wrapping in an extra
/// NavigationStack when this view is hosted inside the More tab's stack.
struct BulletinsView: View {
    var embedded: Bool = false

    @Environment(AppState.self) private var appState
    @State private var viewModel = BulletinsViewModel()
    @State private var taxonomy = BulletinTaxonomyStore()
    @State private var readState = BulletinReadStateStore()
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
        .navigationTitle("公告")
        // Default placement on iOS 26 = navigation bar drawer that
        // reveals on pull-down and collapses on scroll. Liquid Glass
        // styling is applied automatically by the system; we don't
        // call `.glassEffect()` ourselves per HIG guidance.
        .searchable(text: $viewModel.searchText, prompt: "搜尋公告")
        .refreshable { await viewModel.refresh() }
        .toolbar {
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
    }

    // MARK: - Sections

    /// Marker so the filter section disappears entirely when the taxonomy
    /// hasn't loaded — empty array stays out of the List rather than
    /// rendering an empty Section frame.
    private var filtersAvailable: [BulletinAPI.OrgLabel] {
        taxonomy.state.taxonomy?.orgs ?? []
    }

    @ViewBuilder
    private var filtersBlock: some View {
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
                        title: "沒有公告",
                        message: "稍後再回來查看"
                    )
                    .frame(height: 200)
                }
            }
        } else if viewModel.filteredItems.isEmpty {
            centeredRow {
                EmptyStateView(
                    icon: "tray",
                    title: "沒有公告",
                    message: viewModel.hasActiveFilter ? "沒有符合篩選條件的公告" : "稍後再回來查看"
                )
                .frame(height: 200)
            }
        } else {
            ForEach(viewModel.filteredItems) { bulletin in
                NavigationLink {
                    BulletinDetailView(
                        bulletin: bulletin,
                        taxonomy: taxonomy,
                        readState: readState
                    )
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
                        // Icon-only label per spec — system reads it as a
                        // VoiceOver hint, no visible "已讀/未讀" text.
                        Label(
                            readState.isRead(bulletin.id) ? "標示為未讀" : "標示為已讀",
                            systemImage: readState.isRead(bulletin.id)
                                ? "envelope.badge"
                                : "envelope.open"
                        )
                        .labelStyle(.iconOnly)
                    }
                    .tint(.accentColor)
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

    // MARK: - Helpers

    /// Wraps a "centered, full-width" view as a List row with no chrome
    /// (clear background, no separator, no inset). Used for empty / error
    /// / loading states that need to occupy a row but shouldn't look like
    /// data.
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
}

private extension BulletinsViewModel {
    var hasActiveFilter: Bool {
        !selectedOrgs.isEmpty || !selectedTags.isEmpty || !searchText.isEmpty
    }
}
