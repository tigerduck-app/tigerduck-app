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
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = BulletinsViewModel()
    /// Shared across navigations — fetching the taxonomy is a network hop
    /// the user feels as "filter chips missing on entry" every time the
    /// Home widget pushes this view fresh. A singleton keeps the loaded
    /// taxonomy in memory for the app's lifetime.
    private let taxonomy = BulletinTaxonomyStore.shared
    @State private var readState = BulletinReadStateStore()
    @State private var showNotificationSettings: Bool = false
    /// Snapshot of the bulletin captured at push time so the detail
    /// view can render even if `viewModel.items` mutates mid-flight
    /// (retention sweep, refilter, refresh). Without this, the
    /// destination resolved by `items.first(where: { $0.id == id })`
    /// can evaporate, the fallback `.onAppear { id = nil }` fires, and
    /// the navigation stack oscillates.
    @State private var detailingBulletin: BulletinAPI.BulletinSummary?
    /// Deep-link ids currently being resolved. Prevents SwiftUI re-renders
    /// from re-triggering the same fetch while it's in flight and lets us
    /// leave `pendingDeepLink` set until the fetch resolves (so a slow
    /// network doesn't lose the tap by clearing it eagerly).
    @State private var inflightDeepLinkIds: Set<Int> = []
    @State private var unreadOnly: Bool = false
    /// Drives `.searchable`'s expansion — bound so we can force-collapse
    /// it when the app returns to foreground (users expect the search
    /// scope to reset across sessions rather than persist).
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
            // Kick both loads off concurrently — taxonomy and bulletin
            // list are independent, and the list's cache-seed already
            // paints before either resolves.
            async let tax: Void = taxonomy.loadIfNeeded()
            async let bulletins: Void = viewModel.loadIfNeeded()
            _ = await (tax, bulletins)
        }
        .onDisappear { viewModel.pausePrefetch() }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            // Reset search only after more than 5 minutes in the background, so a
            // quick switch to another app keeps the query. Wall time, not the app
            // clock: this measures idle time, and a frozen debug clock must not stop it.
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
            // Retry a deep link an earlier tap could not resolve (poor signal,
            // app suspended mid-fetch). `pendingDeepLink` has not changed, so the
            // `onChange` observer below would not fire again on its own.
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
        // A successful refresh means the network is back and may have pulled the
        // target bulletin into `items`, so retry a deep link kept through an
        // earlier transient failure.
        .onChange(of: viewModel.loadState) { _, newState in
            if case .loaded = newState {
                drainPendingBulletinDeepLink()
            }
        }
        #endif
    }

    #if os(iOS)
    /// Resolve a tap-routed deep link into a navigation push. Done in two
    /// hops because we have to materialise a `BulletinSummary` to feed
    /// `.navigationDestination(item:)` before we can show the detail
    /// view — `summary(forId:)` first checks the live list, then disk
    /// cache, then falls back to the detail endpoint.
    private func drainPendingBulletinDeepLink() {
        guard case .bulletin(let id) = appState.pendingDeepLink else { return }
        // Guard with an inflight set rather than clearing the deep link first:
        // a re-render cannot re-enter the drain for an id still in flight, and a
        // transient failure or cold start leaves `pendingDeepLink` for a retry.
        guard !inflightDeepLinkIds.contains(id) else { return }
        inflightDeepLinkIds.insert(id)
        Task {
            defer { inflightDeepLinkIds.remove(id) }
            let summary: BulletinAPI.BulletinSummary?
            do {
                summary = try await viewModel.summary(forId: id)
            } catch {
                // Transient failure (network drop, timeout): keep `pendingDeepLink`
                // so a later drain (foreground return, list refresh) retries instead
                // of losing the tap on the first poor connection.
                return
            }
            // Terminal outcome — either we have a summary or the bulletin
            // is tombstoned and will never become navigable. Either way,
            // clear the deep link so we don't keep redriving the drain.
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

    private var hasUnreadBulletins: Bool {
        viewModel.items.contains { !readState.isRead($0.id) }
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
        .navigationTitle(String(localized: "feature_announcements"))
        // Default placement on iOS 26 is the navigation bar drawer, revealed on
        // pull-down and collapsed on scroll. The system applies Liquid Glass, so
        // per the HIG this view does not call `.glassEffect()`.
        .searchable(text: $viewModel.searchText, isPresented: $searchIsPresented, prompt: String(localized: "bulletin_search_prompt"))
        .refreshable { await viewModel.refresh() }
        .toolbar {
            // Shown only while filtering to unread with something unread. That gate
            // is why marking all read needs no confirmation step.
            if unreadOnly, hasUnreadBulletins {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "bulletin_mark_all_read_action")) {
                        readState.markAllRead(viewModel.items.map(\.id))
                    }
                }
            }
            // The dot opts out of the shared toolbar background: that capsule spans
            // neighbouring items and stays while the dot fades on idle, leaving an
            // empty pill. Bare also matches the pages that draw it in a plain header row.
            if #available(iOS 26, *) {
                ToolbarItem(placement: .topBarTrailing) {
                    SyncStatusDot(servers: [.backend])
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    SyncStatusDot(servers: [.backend])
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    unreadOnly.toggle()
                } label: {
                    // A filter glyph says "filtering the list" more directly than an
                    // envelope, which reads as notifications. Filled while the filter is on.
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
                // A plain Button, not a NavigationLink, keeps the tap highlight without
                // the trailing chevron. The push runs through the parent List's
                // `.navigationDestination(item:)`.
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
                        // Icon only: the title is still read to VoiceOver, but no
                        // "read/unread" text is visible.
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
