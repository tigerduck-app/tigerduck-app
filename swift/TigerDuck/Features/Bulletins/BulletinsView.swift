import Defaults
import SwiftUI

struct BulletinsView: View {
    var embedded: Bool = false

    @Environment(AppEnvironment.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = BulletinsViewModel()
    @AccountDefault(.bulletinsSyncedAt) private var bulletinsSyncedAt
    private let taxonomy = BulletinTaxonomyStore.shared
    @State private var readState = BulletinReadStateStore()
    @State private var detailingBulletin: BulletinAPI.BulletinSummary?
    @State private var inflightDeepLinkIds: Set<Int> = []
    @State private var unreadOnly: Bool = false
    @State private var searchIsPresented: Bool = false
    @State private var lastBackgroundedAt: Date?

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
        .onChange(of: app.router.pendingDeepLink) { _, _ in
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
        guard case .bulletin(let id) = app.router.pendingDeepLink else { return }
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
            if case .bulletin(let pendingId) = app.router.pendingDeepLink,
               pendingId == id {
                app.router.pendingDeepLink = nil
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
        // Default placement on iOS 26 is the navigation bar drawer, revealed on
        // pull-down and collapsed on scroll. The system applies Liquid Glass, so
        // per the HIG this view does not call `.glassEffect()`.
        .navigationBarSearch(text: $viewModel.searchText, isPresented: $searchIsPresented, prompt: String(localized: "bulletin_search_prompt"))
        .refreshable { await viewModel.refresh() }
        .toolbar {
            BulletinsToolbar(
                unreadOnly: $unreadOnly,
                unreadShown: unreadShown,
                readState: readState,
                bulletinsSyncedAt: bulletinsSyncedAt
            )
        }
        .navigationDestination(item: $detailingBulletin) { row in
            BulletinDetailView(
                bulletin: row,
                taxonomy: taxonomy,
                readState: readState
            )
        }
        .pageMenu(.bulletins)
    }

    private var filtersAvailable: [BulletinAPI.OrgLabel] {
        taxonomy.state.taxonomy?.orgs ?? []
    }

    @ViewBuilder
    private var filtersBlock: some View {
        if let tax = taxonomy.state.taxonomy {
            VStack(spacing: TigerDuckTheme.Spacing.sm) {
                FilterChipBar(
                    title: String(localized: "bulletin_filter_dept"),
                    options: tax.orgs.map { (id: $0.rawId, label: $0.label) },
                    selected: viewModel.selectedOrgs,
                    policy: app.preferences.visualStylePolicy,
                    onToggle: { viewModel.toggleOrg($0) }
                )
                FilterChipBar(
                    title: String(localized: "bulletin_filter_tag"),
                    options: tax.tags.map { (id: $0.rawId, label: $0.label) },
                    selected: viewModel.selectedTags,
                    policy: app.preferences.visualStylePolicy,
                    onToggle: { viewModel.toggleTag($0) }
                )
            }
        }
    }

    private var bodySection: some View {
        BulletinRows(
            viewModel: viewModel,
            taxonomy: taxonomy,
            readState: readState,
            unreadOnly: unreadOnly,
            detailingBulletin: $detailingBulletin
        )
    }
}
