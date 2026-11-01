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

    let feed: BulletinFeed
    private let account: AccountSession
    private(set) var loadState: LoadState = .idle
    private(set) var isPaginating: Bool = false
    private var filter = BulletinFilter() {
        didSet { refilter() }
    }
    var showDeleted: Bool = false {
        didSet { Task { await refresh() } }
    }

    private(set) var filteredItems: [BulletinAPI.BulletinSummary] = []

    private var inflight: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var isPrefetchPaused = false
    private static let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Bulletin.VM")

    init(feed: BulletinFeed? = nil, account: AccountSession = .school) {
        let feed = feed ?? BulletinFeed(for: account.currentSignIn)
        self.feed = feed
        self.account = account
        filteredItems = feed.items
    }

    var items: [BulletinAPI.BulletinSummary] { feed.items }
    var hasMore: Bool { feed.hasMore }
    var selectedOrgs: Set<String> { get { filter.orgs } set { filter.orgs = newValue } }
    var selectedTags: Set<String> { get { filter.tags } set { filter.tags = newValue } }
    var searchText: String { get { filter.searchText } set { filter.searchText = newValue } }
    var hasActiveFilter: Bool { filter.isActive }

    static func forgetAccount(in storage: AccountStorage) {
        forgetListSession()
    }

    static func forgetListSession() {
        BulletinFeed.forgetListSession()
    }

    static func endpointDidChange() {
        BulletinFeed.endpointDidChange()
    }

    func loadIfNeeded() async {
        isPrefetchPaused = false
        if feed.isFromBeforeSignOut { restartAfterSignOut() }
        if case .loaded = loadState {
            resumePrefetchIfNeeded()
            return
        }
        if feed.resumeSession(showDeleted: showDeleted) {
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
        let signIn = await account.startingSignIn
        guard let page = try? await feed.page(after: nil, includeDeleted: includeDeleted),
              includeDeleted == showDeleted else { return }
        if dropsAfterSignOut(signIn) { return }
        noteNewestPage(for: signIn)
        let knownIds = Set(feed.items.map(\.id))
        let reachesKeptRows = page.items.contains { knownIds.contains($0.id) }
        feed.add(page, movesCursor: !reachesKeptRows)
        if !reachesKeptRows { startBackgroundPrefetch() }
        refilter()
        persistSummaries(for: signIn)
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
        guard prefetchTask == nil, feed.hasMore, feed.nextCursor != nil else { return }
        startBackgroundPrefetch()
    }

    func refresh() async {
        if feed.isFromBeforeSignOut { restartAfterSignOut() }
        inflight?.cancel()
        prefetchTask?.cancel()
        inflight = Task { [weak self] in
            await self?.performRefresh()
        }
        await inflight?.value
    }

    func summary(forId id: Int) async throws -> BulletinAPI.BulletinSummary? {
        if feed.isFromBeforeSignOut { restartAfterSignOut() }
        let signIn = await account.startingSignIn
        guard let found = try await feed.summary(forId: id) else { return nil }
        guard found.fetched, !dropsAfterSignOut(signIn) else { return found.summary }
        feed.add(found.summary)
        refilter()
        persistSummaries(for: signIn)
        return found.summary
    }

    func loadMoreIfNeeded(triggeredBy item: BulletinAPI.BulletinSummary) async {
        if feed.isFromBeforeSignOut { return await refresh() }
        guard feed.hasMore, !isPaginating else { return }
        guard let visibleIndex = feed.items.firstIndex(where: { $0.id == item.id }) else { return }
        guard visibleIndex >= max(feed.items.count - 5, 0) else { return }
        await paginate()
    }

    private func performRefresh() async {
        loadState = .loading
        feed.restartWalk()
        let signIn = await account.startingSignIn
        do {
            let page = try await feed.page(after: nil, includeDeleted: showDeleted)
            if dropsAfterSignOut(signIn) { return }
            feed.add(page)
            loadState = .loaded
            noteNewestPage(for: signIn)
            refilter()
            persistSummaries(for: signIn)
            startBackgroundPrefetch()
        } catch {
            Self.logger.error("refresh failed: \(error.localizedDescription, privacy: .private)")
            if feed.items.isEmpty {
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
        let signIn = await account.startingSignIn
        while !Task.isCancelled, feed.hasMore, let cursor = feed.nextCursor {
            do {
                let page = try await feed.page(after: cursor, includeDeleted: showDeleted)
                guard !Task.isCancelled else { return }
                if dropsAfterSignOut(signIn) { return }
                feed.add(page)
                refilter()
                persistSummaries(for: signIn)
                consecutiveFailures = 0
                try? await AppClock.sleep(until: ContinuousClock.now + .milliseconds(200))
            } catch {
                consecutiveFailures += 1
                Self.logger.error("prefetch page failed: \(error.localizedDescription, privacy: .private) attempt=\(consecutiveFailures, privacy: .public)")
                if consecutiveFailures >= 3 {
                    Self.logger.info("prefetch backing off after repeated failures")
                    return
                }
                try? await AppClock.sleep(until: ContinuousClock.now + .seconds(2))
            }
        }
    }

    private func paginate() async {
        guard let cursor = feed.nextCursor else {
            feed.endWalk()
            return
        }
        isPaginating = true
        defer { isPaginating = false }
        let signIn = await account.startingSignIn
        do {
            let page = try await feed.page(after: cursor, includeDeleted: showDeleted)
            if dropsAfterSignOut(signIn) { return }
            feed.add(page)
            refilter()
            persistSummaries(for: signIn)
        } catch {
            Self.logger.error("paginate failed (will retry on next trigger): \(error.localizedDescription, privacy: .private)")
        }
    }

    private func restartAfterSignOut() {
        prefetchTask?.cancel()
        prefetchTask = nil
        feed.restartAfterSignOut(for: account.currentSignIn)
        loadState = .idle
        refilter()
    }

    private func dropsAfterSignOut(_ signIn: SignIn) -> Bool {
        guard !signIn.isCurrent || feed.isFromBeforeSignOut else { return false }
        if feed.isFromBeforeSignOut { restartAfterSignOut() }
        return true
    }

    private func noteNewestPage(for signIn: SignIn) {
        feed.noteSynced(for: signIn)
    }

    private func persistSummaries(for signIn: SignIn) {
        feed.persist(showDeleted: showDeleted, for: signIn)
    }

    private func refilter() {
        filteredItems = filter.apply(to: feed.items)
    }

    func unreadShown(isRead: (Int) -> Bool) -> [Int] {
        filteredItems.filter { !isRead($0.id) }.map(\.id)
    }

    func toggleOrg(_ id: String) { selectedOrgs.formSymmetricDifference([id]) }

    func toggleTag(_ id: String) { selectedTags.formSymmetricDifference([id]) }
}
