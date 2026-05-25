import Foundation
import Observation
import os

/// @Observable store for the bulletin list page.
///
/// Holds a cursor-paginated list, the current filter selection, and the
/// loading state for both the initial fetch and the infinite-scroll
/// pagination. Refresh and pagination share an in-flight `Task` so rapid
/// scroll events never fire duplicate requests.
///
/// Disk cache: `DataCache` persists the full known summary list between
/// launches. On refresh we seed from cache first so the list renders
/// immediately, then hit the server and merge by id. A background task
/// then walks the cursor pages until the server returns `next_cursor =
/// nil`, so the user can scroll the entire history without waiting for
/// 30-item chunks mid-scroll.
@MainActor
@Observable
final class BulletinsViewModel {
    enum LoadState: Sendable, Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var items: [BulletinAPI.BulletinSummary] = []
    private(set) var loadState: LoadState = .idle
    private(set) var isPaginating: Bool = false
    private(set) var hasMore: Bool = true

    private var suppressRefilter = false
    var selectedOrgs: Set<String> = [] {
        didSet { if !suppressRefilter { refilter() } }
    }
    var selectedTags: Set<String> = [] {
        didSet { if !suppressRefilter { refilter() } }
    }
    var searchText: String = "" {
        didSet { if !suppressRefilter { refilter() } }
    }
    var showDeleted: Bool = false {
        didSet { Task { await refresh() } }
    }

    private(set) var filteredItems: [BulletinAPI.BulletinSummary] = []

    private let apiClient: BulletinAPIClient
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Bulletin.VM")
    private var nextCursor: Int? = nil
    private var inflight: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?

    init(apiClient: BulletinAPIClient? = nil) {
        // Defaults to providers that re-resolve through PushServerConfig
        // on every request, so a Debug endpoint override applies to bulletin
        // fetches immediately and the shared secret tracks the endpoint —
        // matching the push stack's behaviour.
        self.apiClient = apiClient ?? BulletinAPIClient()
        // Seed synchronously from disk so the very first render after
        // launch paints real cards instead of a spinner.
        let cached = DataCache.shared.loadBulletinSummaries()
        if !cached.isEmpty {
            items = Self.sortedUnique(cached)
            filteredItems = items
        }
    }

    // MARK: - Public surface

    /// Initial load. No-op if already loaded so tab re-selection does not
    /// thrash the network — call `refresh()` to force.
    func loadIfNeeded() async {
        if case .loaded = loadState { return }
        await refresh()
    }

    func refresh() async {
        inflight?.cancel()
        prefetchTask?.cancel()
        inflight = Task { [weak self] in
            await self?.performRefresh()
        }
        await inflight?.value
    }

    /// Resolve a bulletin id (typically from a push-tap deep link) into a
    /// `BulletinSummary` the view can hand to its `.navigationDestination`.
    /// Prefers the in-memory list, then the on-disk summary cache, and as
    /// a last resort fetches the detail endpoint and synthesises a summary
    /// shaped row from it — that mirror lets `BulletinDetailView` re-fetch
    /// the same detail and render normally without an extra contract.
    func summary(forId id: Int) async -> BulletinAPI.BulletinSummary? {
        if let existing = items.first(where: { $0.id == id }) {
            return existing
        }
        let cached = DataCache.shared.loadBulletinSummaries()
        if let hit = cached.first(where: { $0.id == id }) {
            return hit
        }
        do {
            let detail = try await apiClient.getBulletin(id: id)
            // Don't surface or merge a tombstoned bulletin — the /list
            // endpoint filters these out, and merging here would inject
            // a ghost row at the top of the feed AND persist it to disk
            // cache where it would survive until the next page load
            // overwrote it.
            guard !detail.isDeleted else {
                logger.info("summary(forId:) skipped deleted bulletin id=\(id, privacy: .public)")
                return nil
            }
            let synthesised = BulletinAPI.BulletinSummary(
                id: detail.id,
                externalId: detail.externalId,
                title: detail.title,
                titleClean: detail.titleClean,
                canonicalOrg: detail.canonicalOrg,
                contentTags: detail.contentTags,
                importance: detail.importance,
                summary: detail.summary,
                sourceUrl: detail.sourceUrl,
                postedAt: detail.postedAt,
                isDeleted: detail.isDeleted
            )
            // Merge into the live list so a subsequent return to the list
            // shows the row without another network round trip.
            items = Self.merge(existing: items, incoming: [synthesised])
            refilter()
            persistSummaries()
            return synthesised
        } catch {
            logger.error("summary(forId:) fetch failed id=\(id, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Request the next page. Safe to call on every scroll — guarded by
    /// `isPaginating` and `hasMore`.
    func loadMoreIfNeeded(triggeredBy item: BulletinAPI.BulletinSummary) async {
        guard hasMore, !isPaginating else { return }
        // Only paginate when approaching the tail of the loaded list. The
        // filter chips can keep `filteredItems` much shorter than `items`,
        // so we key the threshold off `items` to avoid a pagination storm
        // when heavy filtering shows a short filtered list.
        guard let visibleIndex = items.firstIndex(where: { $0.id == item.id }) else { return }
        guard visibleIndex >= max(items.count - 5, 0) else { return }
        await paginate()
    }

    // MARK: - Internals

    private func performRefresh() async {
        loadState = .loading
        nextCursor = nil
        do {
            let page = try await apiClient.listBulletins(
                limit: 30,
                cursor: nil,
                includeDeleted: showDeleted
            )
            // Merge fresh items on top of the cache. The server is the
            // source of truth for everything it returns; cache supplies
            // older rows the server hasn't paged to yet.
            items = Self.merge(existing: items, incoming: page.items)
            nextCursor = page.nextCursor
            hasMore = page.nextCursor != nil
            loadState = .loaded
            refilter()
            persistSummaries()
            startBackgroundPrefetch()
        } catch {
            logger.error("refresh failed: \(error.localizedDescription, privacy: .public)")
            // If we have cached items, keep them visible and surface as
            // `loaded` rather than `failed` — the user can still browse
            // history while offline. Surface the error only when there is
            // literally nothing to show.
            if items.isEmpty {
                loadState = .failed(error.localizedDescription)
            } else {
                loadState = .loaded
            }
        }
    }

    /// Eagerly paginate through every remaining page in the background so
    /// the user never stops mid-scroll. Runs at user-initiated priority
    /// (kills itself if the view refreshes or disappears) and yields
    /// between pages so the UI stays responsive. Resilient to transient
    /// errors: a failed page schedules a short retry rather than killing
    /// the chain.
    private func startBackgroundPrefetch() {
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            await self?.runBackgroundPrefetch()
        }
    }

    private func runBackgroundPrefetch() async {
        var consecutiveFailures = 0
        while !Task.isCancelled, hasMore, let cursor = nextCursor {
            do {
                let page = try await apiClient.listBulletins(
                    limit: 30,
                    cursor: cursor,
                    includeDeleted: showDeleted
                )
                items = Self.merge(existing: items, incoming: page.items)
                nextCursor = page.nextCursor
                hasMore = page.nextCursor != nil
                refilter()
                persistSummaries()
                consecutiveFailures = 0
                // Small yield so a 500ms backlog pull doesn't starve the
                // main thread if the user is actively scrolling.
                try? await Task.sleep(for: .milliseconds(200))
            } catch {
                consecutiveFailures += 1
                logger.error("prefetch page failed: \(error.localizedDescription, privacy: .public) attempt=\(consecutiveFailures, privacy: .public)")
                if consecutiveFailures >= 3 {
                    // Give up for this session; the user can pull-to-refresh
                    // later to restart the prefetch chain. Note we leave
                    // `hasMore = true` so manual scroll still retries.
                    logger.info("prefetch backing off after repeated failures")
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func paginate() async {
        guard let cursor = nextCursor else {
            hasMore = false
            return
        }
        isPaginating = true
        defer { isPaginating = false }
        do {
            let page = try await apiClient.listBulletins(
                limit: 30,
                cursor: cursor,
                includeDeleted: showDeleted
            )
            items = Self.merge(existing: items, incoming: page.items)
            nextCursor = page.nextCursor
            hasMore = page.nextCursor != nil
            refilter()
            persistSummaries()
        } catch {
            // Preserve `hasMore` and `nextCursor` so the next scroll
            // trigger (or a pull-to-refresh) retries this page. The prior
            // behaviour of setting `hasMore = false` here meant a single
            // network blip could silently strand the user at page N,
            // which is exactly what we saw stopping scrolling at March.
            logger.error("paginate failed (will retry on next trigger): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistSummaries() {
        DataCache.shared.saveBulletinSummaries(items)
    }

    /// Dedupe by id and sort newest-first. Server-side ordering is
    /// `(posted_at DESC, id DESC)`, so mirror that to keep local merges
    /// consistent with what the next server page will deliver.
    private static func merge(
        existing: [BulletinAPI.BulletinSummary],
        incoming: [BulletinAPI.BulletinSummary]
    ) -> [BulletinAPI.BulletinSummary] {
        var byId: [Int: BulletinAPI.BulletinSummary] = [:]
        for row in existing { byId[row.id] = row }
        for row in incoming { byId[row.id] = row }
        return sortedUnique(Array(byId.values))
    }

    private static func sortedUnique(
        _ rows: [BulletinAPI.BulletinSummary]
    ) -> [BulletinAPI.BulletinSummary] {
        let distantPast = Date.distantPast
        return rows.sorted { lhs, rhs in
            let ld = lhs.postedAt ?? distantPast
            let rd = rhs.postedAt ?? distantPast
            if ld != rd { return ld > rd }
            return lhs.id > rhs.id
        }
    }

    private func refilter() {
        var result = items
        if !selectedOrgs.isEmpty {
            result = result.filter { row in
                guard let org = row.canonicalOrg else { return false }
                return selectedOrgs.contains(org)
            }
        }
        if !selectedTags.isEmpty {
            result = result.filter { row in
                !Set(row.contentTags).isDisjoint(with: selectedTags)
            }
        }
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            result = result.filter { row in
                row.displayTitle.localizedCaseInsensitiveContains(trimmed) ||
                row.title.localizedCaseInsensitiveContains(trimmed) ||
                (row.summary?.localizedCaseInsensitiveContains(trimmed) ?? false)
            }
        }
        filteredItems = result
    }

    /// Expose a helper so views can quickly toggle single filters.
    func toggleOrg(_ id: String) {
        if selectedOrgs.contains(id) {
            selectedOrgs.remove(id)
        } else {
            selectedOrgs.insert(id)
        }
    }

    func toggleTag(_ id: String) {
        if selectedTags.contains(id) {
            selectedTags.remove(id)
        } else {
            selectedTags.insert(id)
        }
    }

    func clearFilters() {
        // Batch-mutate so refilter() runs once instead of three times over
        // potentially thousands of items.
        suppressRefilter = true
        selectedOrgs.removeAll()
        selectedTags.removeAll()
        searchText = ""
        suppressRefilter = false
        refilter()
    }
}
