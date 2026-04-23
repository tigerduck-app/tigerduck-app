import Foundation
import Observation
import os

/// @Observable store for the bulletin list page.
///
/// Holds a cursor-paginated list, the current filter selection, and the
/// loading state for both the initial fetch and the infinite-scroll
/// pagination. Refresh and pagination share an in-flight `Task` so rapid
/// scroll events never fire duplicate requests.
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

    init(apiClient: BulletinAPIClient? = nil) {
        self.apiClient = apiClient ?? BulletinAPIClient(
            baseURL: PushCoordinator.resolveServerURL(),
            sharedSecret: PushCoordinator.resolveSharedSecret()
        )
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
        inflight = Task { [weak self] in
            await self?.performRefresh()
        }
        await inflight?.value
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
            items = page.items
            nextCursor = page.nextCursor
            hasMore = page.nextCursor != nil
            loadState = .loaded
            refilter()
        } catch {
            logger.error("refresh failed: \(error.localizedDescription, privacy: .public)")
            loadState = .failed(error.localizedDescription)
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
            items.append(contentsOf: page.items)
            nextCursor = page.nextCursor
            hasMore = page.nextCursor != nil
            refilter()
        } catch {
            logger.error("paginate failed: \(error.localizedDescription, privacy: .public)")
            hasMore = false
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
        selectedOrgs.removeAll()
        selectedTags.removeAll()
        searchText = ""
    }
}
