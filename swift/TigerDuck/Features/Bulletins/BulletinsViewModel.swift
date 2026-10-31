import Defaults
import Foundation
import Observation
import os

@MainActor
@Observable
final class BulletinsViewModel: AccountScoped {
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

    var selectedOrgs: Set<String> = [] {
        didSet { refilter() }
    }
    var selectedTags: Set<String> = [] {
        didSet { refilter() }
    }
    var searchText: String = "" {
        didSet { refilter() }
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
    private var isPrefetchPaused = false
    @ObservationIgnored private var itemsEpoch = BulletinsViewModel.listEpoch

    init(apiClient: BulletinAPIClient? = nil) {
        self.apiClient = apiClient ?? BulletinAPIClient()
        let cached = BulletinFiles.shared.loadBulletinSummaries()
        if !cached.isEmpty {
            items = Self.sortedUnique(cached)
            filteredItems = items
        }
    }

    private struct ListSession {
        let items: [BulletinAPI.BulletinSummary]
        let nextCursor: Int?
        let hasMore: Bool
        let showDeleted: Bool
    }

    private static var listSession: ListSession?
    private static var listEpoch = 0

    static func forgetAccount(in storage: AccountStorage) {
        forgetListSession()
    }

    static func forgetListSession() {
        listSession = nil
        listEpoch &+= 1
        Defaults[.bulletinsSyncedAt] = nil
    }

    /// Another backend numbers its bulletins apart, so the old rows cannot be merged with its pages.
    static func endpointDidChange() {
        BulletinFiles.shared.saveBulletinSummaries([])
        BulletinFiles.shared.clearBulletinDetails()
        forgetListSession()
    }

    func loadIfNeeded() async {
        isPrefetchPaused = false
        if isFromBeforeSignOut { restartAfterSignOut() }
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
            await refreshFirstPage()
            return
        }
        await refresh()
    }

    private func refreshFirstPage() async {
        let includeDeleted = showDeleted
        let epoch = Self.listEpoch
        guard let page = try? await apiClient.listBulletins(
            limit: 30, cursor: nil, includeDeleted: includeDeleted
        ), includeDeleted == showDeleted else { return }
        if dropsAfterSignOut(epoch) { return }
        noteNewestPage()
        let knownIds = Set(items.map(\.id))
        let reachesKeptRows = page.items.contains { knownIds.contains($0.id) }
        items = Self.merge(existing: items, incoming: page.items)
        if !reachesKeptRows {
            nextCursor = page.nextCursor
            hasMore = page.nextCursor != nil
            startBackgroundPrefetch()
        }
        refilter()
        persistSummaries()
    }

    func waitForPrefetch() async {
        await prefetchTask?.value
    }

    func pausePrefetch() {
        isPrefetchPaused = true
        prefetchTask?.cancel()
        prefetchTask = nil
    }

    private func resumePrefetchIfNeeded() {
        guard prefetchTask == nil, hasMore, nextCursor != nil else { return }
        startBackgroundPrefetch()
    }

    func refresh() async {
        if isFromBeforeSignOut { restartAfterSignOut() }
        inflight?.cancel()
        prefetchTask?.cancel()
        inflight = Task { [weak self] in
            await self?.performRefresh()
        }
        await inflight?.value
    }

    func summary(forId id: Int) async throws -> BulletinAPI.BulletinSummary? {
        if isFromBeforeSignOut { restartAfterSignOut() }
        if let existing = items.first(where: { $0.id == id }) {
            guard !existing.isDeleted else {
                logger.info("summary(forId:) skipped in-memory deleted bulletin id=\(id, privacy: .public)")
                return nil
            }
            return existing
        }
        let cached = BulletinFiles.shared.loadBulletinSummaries()
        if let hit = cached.first(where: { $0.id == id }) {
            guard !hit.isDeleted else {
                logger.info("summary(forId:) skipped cached deleted bulletin id=\(id, privacy: .public)")
                return nil
            }
            return hit
        }
        let epoch = Self.listEpoch
        let detail: BulletinAPI.BulletinDetail
        do {
            detail = try await apiClient.getBulletin(id: id)
        } catch {
            logger.error("summary(forId:) fetch failed id=\(id, privacy: .public) error=\(error.localizedDescription, privacy: .private)")
            throw error
        }
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
        if dropsAfterSignOut(epoch) { return synthesised }
        items = Self.merge(existing: items, incoming: [synthesised])
        refilter()
        persistSummaries()
        return synthesised
    }

    func loadMoreIfNeeded(triggeredBy item: BulletinAPI.BulletinSummary) async {
        if isFromBeforeSignOut { return await refresh() }
        guard hasMore, !isPaginating else { return }
        guard let visibleIndex = items.firstIndex(where: { $0.id == item.id }) else { return }
        guard visibleIndex >= max(items.count - 5, 0) else { return }
        await paginate()
    }

    private func performRefresh() async {
        loadState = .loading
        nextCursor = nil
        let epoch = Self.listEpoch
        do {
            let page = try await apiClient.listBulletins(
                limit: 30,
                cursor: nil,
                includeDeleted: showDeleted
            )
            if dropsAfterSignOut(epoch) { return }
            items = Self.merge(existing: items, incoming: page.items)
            nextCursor = page.nextCursor
            hasMore = page.nextCursor != nil
            loadState = .loaded
            noteNewestPage()
            refilter()
            persistSummaries()
            startBackgroundPrefetch()
        } catch {
            logger.error("refresh failed: \(error.localizedDescription, privacy: .private)")
            if items.isEmpty {
                loadState = .failed(error.localizedDescription)
            } else {
                loadState = .loaded
            }
        }
    }

    private func startBackgroundPrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
        guard !isPrefetchPaused else { return }
        prefetchTask = Task { [weak self] in
            await self?.runBackgroundPrefetch()
        }
    }

    private func runBackgroundPrefetch() async {
        var consecutiveFailures = 0
        let epoch = Self.listEpoch
        while !Task.isCancelled, hasMore, let cursor = nextCursor {
            do {
                let page = try await apiClient.listBulletins(
                    limit: 30,
                    cursor: cursor,
                    includeDeleted: showDeleted
                )
                if dropsAfterSignOut(epoch) { return }
                items = Self.merge(existing: items, incoming: page.items)
                nextCursor = page.nextCursor
                hasMore = page.nextCursor != nil
                refilter()
                persistSummaries()
                consecutiveFailures = 0
                try? await Task.sleep(for: .milliseconds(200))
            } catch {
                consecutiveFailures += 1
                logger.error("prefetch page failed: \(error.localizedDescription, privacy: .private) attempt=\(consecutiveFailures, privacy: .public)")
                if consecutiveFailures >= 3 {
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
        let epoch = Self.listEpoch
        do {
            let page = try await apiClient.listBulletins(
                limit: 30,
                cursor: cursor,
                includeDeleted: showDeleted
            )
            if dropsAfterSignOut(epoch) { return }
            items = Self.merge(existing: items, incoming: page.items)
            nextCursor = page.nextCursor
            hasMore = page.nextCursor != nil
            refilter()
            persistSummaries()
        } catch {
            logger.error("paginate failed (will retry on next trigger): \(error.localizedDescription, privacy: .private)")
        }
    }

    private var isFromBeforeSignOut: Bool { itemsEpoch != Self.listEpoch }

    private func restartAfterSignOut() {
        prefetchTask?.cancel()
        prefetchTask = nil
        items = Self.sortedUnique(BulletinFiles.shared.loadBulletinSummaries())
        nextCursor = nil
        hasMore = true
        loadState = .idle
        itemsEpoch = Self.listEpoch
        refilter()
    }

    private func dropsAfterSignOut(_ epoch: Int) -> Bool {
        guard epoch != Self.listEpoch || isFromBeforeSignOut else { return false }
        if isFromBeforeSignOut { restartAfterSignOut() }
        return true
    }

    private func noteNewestPage() {
        Defaults[.bulletinsSyncedAt] = Date()
    }

    private func persistSummaries() {
        BulletinFiles.shared.saveBulletinSummaries(items)
        Self.listSession = ListSession(
            items: items, nextCursor: nextCursor, hasMore: hasMore, showDeleted: showDeleted
        )
    }

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

    func unreadShown(isRead: (Int) -> Bool) -> [Int] {
        filteredItems.filter { !isRead($0.id) }.map(\.id)
    }

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
}
