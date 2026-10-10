import Foundation
import Observation
import os

/// Store for the bulletin list page: a cursor-paginated list, the filter
/// selection, and the load state for the first fetch and infinite scroll.
/// Rapid scroll events never fire duplicate requests.
///
/// `DataCache` keeps the full known summary list between launches, so the list
/// renders from disk at once and then merges server pages by id. A background
/// task walks the cursor pages until `next_cursor` is nil, so the user can
/// scroll the whole history without waiting for 30-item pages mid-scroll.
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
        // The default providers re-resolve PushServerConfig on every request, as the
        // push stack does, so a Debug endpoint override applies to bulletin fetches
        // at once and the shared secret follows the endpoint.
        self.apiClient = apiClient ?? BulletinAPIClient()
        // Seed synchronously from disk so the very first render after
        // launch paints real cards instead of a spinner.
        let cached = DataCache.shared.loadBulletinSummaries()
        if !cached.isEmpty {
            items = Self.sortedUnique(cached)
            filteredItems = items
        }
    }

    /// What the last list ended with. More and Home build a new view model on every visit, so
    /// the next one in this process shows it and resumes the cursor instead of fetching the
    /// first page and walking every page behind it again. A pull refreshes it.
    private struct ListSession {
        let items: [BulletinAPI.BulletinSummary]
        let nextCursor: Int?
        let hasMore: Bool
        let showDeleted: Bool
    }

    private static var listSession: ListSession?

    static func forgetListSession() {
        listSession = nil
    }

    // MARK: - Public surface

    /// Initial load. No-op if already loaded so tab re-selection does not
    /// thrash the network — call `refresh()` to force.
    func loadIfNeeded() async {
        if case .loaded = loadState {
            resumePrefetchIfNeeded()
            return
        }
        if let session = Self.listSession, session.showDeleted == showDeleted {
            items = Self.merge(existing: items, incoming: session.items)
            nextCursor = session.nextCursor
            hasMore = session.hasMore
            loadState = .loaded
            refilter()
            resumePrefetchIfNeeded()
            return
        }
        await refresh()
    }

    /// The list left the screen; its next appearance resumes from the cursor.
    func pausePrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
    }

    private func resumePrefetchIfNeeded() {
        guard prefetchTask == nil, hasMore, nextCursor != nil else { return }
        startBackgroundPrefetch()
    }

    func refresh() async {
        inflight?.cancel()
        prefetchTask?.cancel()
        inflight = Task { [weak self] in
            await self?.performRefresh()
        }
        await inflight?.value
    }

    /// Resolve a bulletin id, typically from a push-tap deep link, into a
    /// `BulletinSummary` for the view's `.navigationDestination`. Tries the
    /// in-memory list, then the disk cache, then builds a summary from the
    /// detail endpoint, so `BulletinDetailView` re-fetches and renders it as usual.
    ///
    /// Returns `nil` when the bulletin is tombstoned and can never open. Throws
    /// on a transient miss (network or decode failure) so the caller can keep
    /// the deep link and retry instead of dropping the tap.
    func summary(forId id: Int) async throws -> BulletinAPI.BulletinSummary? {
        if let existing = items.first(where: { $0.id == id }) {
            // `items` is seeded from the disk cache at init, so it can hold a row
            // the server has since tombstoned. Honour the flag here too, as the
            // cache and detail-fetch guards do.
            guard !existing.isDeleted else {
                logger.info("summary(forId:) skipped in-memory deleted bulletin id=\(id, privacy: .public)")
                return nil
            }
            return existing
        }
        let cached = DataCache.shared.loadBulletinSummaries()
        if let hit = cached.first(where: { $0.id == id }) {
            // Cache can hold a pre-tombstone row written before the server
            // marked the bulletin deleted; honour the flag here so the tap
            // doesn't land on a ghost detail page.
            guard !hit.isDeleted else {
                logger.info("summary(forId:) skipped cached deleted bulletin id=\(id, privacy: .public)")
                return nil
            }
            return hit
        }
        let detail: BulletinAPI.BulletinDetail
        do {
            detail = try await apiClient.getBulletin(id: id)
        } catch {
            logger.error("summary(forId:) fetch failed id=\(id, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            throw error
        }
        // Never surface or merge a tombstoned bulletin. /list filters them out, and
        // merging one would put a ghost row at the top of the feed and persist it
        // to the disk cache until a later page load overwrote it.
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
    }

    /// Request the next page. Safe to call on every scroll — guarded by
    /// `isPaginating` and `hasMore`.
    func loadMoreIfNeeded(triggeredBy item: BulletinAPI.BulletinSummary) async {
        guard hasMore, !isPaginating else { return }
        // Paginate only near the tail of `items`, not `filteredItems`: heavy
        // filtering can leave a short filtered list, and keying the threshold
        // off it would set off a pagination storm.
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
            // With cached items, stay `loaded` so the user can browse history
            // offline. Fail only when there is nothing to show.
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
            // Keep `hasMore` and `nextCursor` so the next scroll trigger or a
            // pull-to-refresh retries this page. Clearing `hasMore` here would let
            // one network blip silently strand the user mid-history.
            logger.error("paginate failed (will retry on next trigger): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistSummaries() {
        DataCache.shared.saveBulletinSummaries(items)
        Self.listSession = ListSession(
            items: items, nextCursor: nextCursor, hasMore: hasMore, showDeleted: showDeleted
        )
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
