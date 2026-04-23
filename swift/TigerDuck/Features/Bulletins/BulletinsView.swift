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
    @State private var detailingBulletinId: Int?
    @State private var unreadOnly: Bool = false
    /// Gated by a long-press on the filter toolbar button. We surface the
    /// bulk "mark all as read" action here instead of a separate button
    /// so the primary toolbar stays uncluttered.
    @State private var showMarkAllReadConfirm: Bool = false

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
                    unreadOnly.toggle()
                } label: {
                    // Filter chevron swaps to the filled variant when the
                    // "unread only" filter is active — a filter glyph reads
                    // as "filtering the list" more directly than the prior
                    // envelope, which conflated with notifications.
                    Image(systemName: unreadOnly
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
                        .symbolRenderingMode(.hierarchical)
                }
                .accessibilityLabel(unreadOnly ? "顯示全部公告" : "只看未讀")
                // Long-press surfaces a bulk "全部已讀" action behind a
                // confirmation sheet so accidental presses don't nuke the
                // unread state.
                .onLongPressGesture(minimumDuration: 0.4) {
                    showMarkAllReadConfirm = true
                }
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
        .confirmationDialog(
            "將目前載入的公告全部標示為已讀？",
            isPresented: $showMarkAllReadConfirm,
            titleVisibility: .visible
        ) {
            Button("全部標示為已讀") {
                readState.markAllRead(viewModel.items.map(\.id))
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("共 \(viewModel.items.count) 則公告")
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: showMarkAllReadConfirm) { _, new in new }
        .navigationDestination(item: $detailingBulletinId) { id in
            if let row = viewModel.items.first(where: { $0.id == id }) {
                BulletinDetailView(
                    bulletin: row,
                    taxonomy: taxonomy,
                    readState: readState
                )
            } else {
                // Row evaporated mid-flight (deleted by retention sweep).
                // Bounce back rather than render a stale shell.
                Color.clear.onAppear { detailingBulletinId = nil }
            }
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
        } else if displayedItems.isEmpty {
            centeredRow {
                EmptyStateView(
                    icon: unreadOnly ? "envelope.open" : "tray",
                    title: unreadOnly ? "沒有未讀公告" : "沒有公告",
                    message: viewModel.hasActiveFilter || unreadOnly
                        ? "沒有符合條件的公告"
                        : "稍後再回來查看"
                )
                .frame(height: 200)
            }
        } else {
            ForEach(displayedItems) { bulletin in
                // Plain Button (not NavigationLink) so the row keeps the
                // standard tap-to-highlight feedback without rendering
                // the trailing chevron the user asked us to remove.
                // Programmatic push via .navigationDestination(item:)
                // attached to the parent List.
                Button {
                    detailingBulletinId = bulletin.id
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

    /// Layer the local "unread only" toggle on top of the view-model's
    /// filtered items. Keeping read-state filtering at the View layer (not
    /// in the VM) avoids coupling BulletinsViewModel to the persistence
    /// store and matches how the swipe action mutates state in place.
    private var displayedItems: [BulletinAPI.BulletinSummary] {
        if unreadOnly {
            return viewModel.filteredItems.filter { !readState.isRead($0.id) }
        }
        return viewModel.filteredItems
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
