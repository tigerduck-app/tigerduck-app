#if os(iOS)
import Foundation
import Observation

@MainActor
@Observable
final class MailListViewModel {
    enum LoadState: Equatable {
        case idle, loading, loaded
        case failed(String)
    }

    private(set) var folderRoles: [MailFolderRole: String] = [:]
    private(set) var otherFolders: [String] = []
    private(set) var selection: MailFolderSelection = .real(MailConstants.inbox)
    private(set) var rows: [MailListRow] = []
    private(set) var loadState: LoadState = .idle
    private(set) var serverStatus: ServerStatus = .unknown
    private(set) var syncedAt: Date?
    private(set) var isRefreshing = false
    private(set) var isPaginating = false
    private(set) var searchResults: [MailListRow]?
    private(set) var searchUsedLocalFallback = false
    private(set) var sentCopyNotice: String?
    var searchText = ""
    var unreadOnly = false

    @ObservationIgnored let session: MailPageSession
    @ObservationIgnored private let cache: MailCache
    @ObservationIgnored private let noteSeenByPage: (MailboxStatusInfo) async -> Void
    @ObservationIgnored private var pages: [String: MailFolderPage] = [:]
    @ObservationIgnored private var cachePaintedFolders: Set<String> = []
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var loadingSelection: MailFolderSelection?
    @ObservationIgnored private var selectionWasChosen = false
    @ObservationIgnored private var pendingCacheWrite: Task<Void, Never>?
    @ObservationIgnored private var accountEpoch = 0
    @ObservationIgnored private var unfetchedMatches: [String: (uidValidity: UInt32, uids: [UInt32])] = [:]
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private var warmTask: Task<Void, Never>?
    @ObservationIgnored private var warmDone = false
    @ObservationIgnored private var isPaused = false
    @ObservationIgnored private let warmDelay: @Sendable () async -> Void
    @ObservationIgnored nonisolated(unsafe) private var signOutObserver: (any NSObjectProtocol)?
    @ObservationIgnored private let signOutEvents: NotificationCenter

    init(
        session: MailPageSession? = nil,
        cache: MailCache? = nil,
        noteSeenByPage: ((MailboxStatusInfo) async -> Void)? = nil,
        signOutEvents: NotificationCenter = .default,
        warmDelay: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: MailConstants.warmStartDelay) }
    ) {
        self.session = session ?? MailPageSession()
        self.cache = cache ?? MailAccountManager.shared.cache
        self.noteSeenByPage = noteSeenByPage ?? { await MailChecker.shared.noteSeenByPage($0) }
        self.signOutEvents = signOutEvents
        self.warmDelay = warmDelay
        signOutObserver = signOutEvents.addObserver(forName: MailAccountManager.didSignOut, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.resetForAccountChange() }
        }
    }

    deinit {
        if let signOutObserver { signOutEvents.removeObserver(signOutObserver) }
    }

    private func isCurrent(_ selection: MailFolderSelection, _ epoch: Int) -> Bool {
        selection == self.selection && epoch == accountEpoch
    }

    var displayedRows: [MailListRow] {
        let base = searchResults ?? rows
        return unreadOnly ? base.filter { !$0.summary.isSeen } : base
    }

    var targets: [String] { selection.targets(roles: folderRoles) }

    var showsAllMailChip: Bool { MailFolderSelection.allMail.targets(roles: folderRoles).count > 1 }

    var showsInbox: Bool { targets.contains(MailConstants.inbox) }

    func load() async {
        var selection = self.selection
        let epoch = accountEpoch
        guard loadingSelection != selection else { return }
        loadingSelection = selection
        defer { if epoch == accountEpoch, loadingSelection == selection { loadingSelection = nil } }

        if await paintFromCache() {
            loadState = .loaded
        } else if rows.isEmpty {
            loadState = .loading
        }
        isRefreshing = true
        defer { if isCurrent(selection, epoch), loadingSelection == selection { isRefreshing = false } }
        do {
            if folderRoles.isEmpty {
                let available = try await session.use { client in try await client.listFolders() }
                guard epoch == accountEpoch else { return }
                folderRoles = MailFolderMap.resolve(available: available)
                otherFolders = MailFolderMap.otherFolders(available: available)
                guard isCurrent(selection, epoch) else { return }
                if adoptDefaultSelection() {
                    selection = self.selection
                    loadingSelection = selection
                }
                if await paintFromCache() { loadState = .loaded }
            }
            guard isCurrent(selection, epoch) else { return }
            let folders = targets
            let fetched = try await session.use { client -> [(String, MailFolderPage)] in
                var result: [(String, MailFolderPage)] = []
                for folder in folders {
                    result.append((folder, try await client.page(folder: folder, olderThanSequence: nil,
                                                                 pageSize: MailConstants.pageSize)))
                }
                return result
            }
            guard isCurrent(selection, epoch) else { return }
            let fetchedAt = Date()
            for (folder, page) in fetched {
                var fresh = page
                fresh.fetchedAt = fetchedAt
                if let previous = pages[folder], previous.uidValidity != fresh.uidValidity {
                    await dropFolder(folder)
                    pages[folder] = nil
                    guard isCurrent(selection, epoch) else { return }
                }
                var merged = mergeFreshPage(fresh, folder: folder)
                rebuildRows()
                if merged.summaries.isEmpty, merged.messageCount > 0 {
                    merged = await walkBackToVisibleMail(from: merged, folder: folder)
                }
                guard isCurrent(selection, epoch) else { return }
                await save(merged)
            }
            rebuildRows()
            serverStatus = .ok
            loadState = .loaded
        } catch {
            guard isCurrent(selection, epoch) else { return }
            serverStatus = .failed
            loadState = rows.isEmpty ? .failed(MailAccountManager.LoginError(error).message) : .loaded
        }
    }

    func refresh() async {
        cancelWarm()
        await load()
        startWarmIfLoaded()
    }

    func loadMoreIfNeeded(after row: MailListRow) async {
        guard !isPaginating, row.id == displayedRows.last?.id else { return }
        guard searchResults == nil else { return await loadMoreSearchResults() }
        let selection = self.selection
        let epoch = accountEpoch
        let cursors = targets.compactMap { folder in pages[folder]?.oldestLoadedSequence.map { (folder, $0) } }
        guard !cursors.isEmpty else { return }
        isPaginating = true
        defer { isPaginating = false }
        for (folder, first) in cursors {
            var cursor: Int? = first
            var extraPages = 0
            while let older = cursor {
                do {
                    let next = try await session.use { client in
                        try await client.page(folder: folder, olderThanSequence: older, pageSize: MailConstants.pageSize)
                    }
                    guard isCurrent(selection, epoch), let page = pages[folder] else { return }
                    guard next.uidValidity == page.uidValidity else {
                        await recoverFromFolderChange(folder)
                        return
                    }
                    let lowest = page.summaries.map(\.uid).min()
                    let merged = Self.mergeOlderPage(next, into: page)
                    pages[folder] = merged
                    rebuildRows()
                    let addedOlder = lowest.map { lowest in merged.summaries.contains { $0.uid < lowest } } ?? !merged.summaries.isEmpty
                    if addedOlder || extraPages == MailConstants.emptyWindowWalkbackPages {
                        cursor = nil
                    } else {
                        cursor = next.oldestLoadedSequence
                        extraPages += 1
                    }
                } catch MailClientError.folderChanged {
                    await recoverFromFolderChange(folder)
                    return
                } catch {
                    guard isCurrent(selection, epoch) else { return }
                    serverStatus = .failed
                    return
                }
            }
        }
    }

    func select(_ selection: MailFolderSelection) async {
        selectionWasChosen = true
        guard selection != self.selection else { return }
        self.selection = selection
        pages = [:]
        rebuildRows()
        searchResults = nil
        searchUsedLocalFallback = false
        cancelWarm()
        await load()
        startWarmIfLoaded()
    }

    func adoptFolderRoles(_ roles: [MailFolderRole: String]) {
        guard roles != folderRoles else { return }
        let before = targets
        folderRoles = roles
        guard targets != before else { return }
        Task { await load() }
    }

    func reportSentCopyNotice(_ message: String) {
        sentCopyNotice = message
    }

    func dismissSentCopyNotice() {
        sentCopyNotice = nil
    }

    func submitSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            clearSearch()
            return
        }
        let selection = self.selection
        let epoch = accountEpoch
        searchGeneration += 1
        let generation = searchGeneration
        var found: [MailListRow] = []
        var unfetched: [String: (uidValidity: UInt32, uids: [UInt32])] = [:]
        var usedFallback = false
        var serverFailed = false
        var recreated: [String] = []
        for folder in targets {
            do {
                let (matched, rest) = try await session.use { client -> ([MailSummary], (uidValidity: UInt32, uids: [UInt32])) in
                    let result = try await client.search(folder: folder, query: query)
                    let matches = result.uids.sorted(by: >)
                    let newest = Array(matches.prefix(MailConstants.pageSize))
                    let summaries = try await client.summaries(folder: folder, uids: newest, expectedUIDValidity: result.uidValidity)
                    return (summaries, (result.uidValidity, Array(matches.dropFirst(newest.count))))
                }
                guard isCurrent(selection, epoch), generation == searchGeneration else { return }
                found += matched.filter { !$0.isDeleted }.map { MailListRow(folder: folder, summary: $0) }
                unfetched[folder] = rest
            } catch MailClientError.folderChanged {
                guard isCurrent(selection, epoch) else { return }
                recreated.append(folder)
            } catch {
                guard isCurrent(selection, epoch) else { return }
                if (error as? MailClientError) != .searchUnsupported { serverFailed = true }
                found += (pages[folder]?.summaries ?? [])
                    .filter { Self.matches($0, query) }
                    .map { MailListRow(folder: folder, summary: $0) }
                usedFallback = true
            }
        }
        guard isCurrent(selection, epoch), generation == searchGeneration else { return }
        if serverFailed { serverStatus = .failed }
        searchResults = ordered(found)
        unfetchedMatches = unfetched
        searchUsedLocalFallback = usedFallback
        for folder in recreated { await recoverFromFolderChange(folder) }
        if displayedRows.isEmpty { await loadMoreSearchResults() }
    }

    private func loadMoreSearchResults() async {
        let selection = self.selection
        let epoch = accountEpoch
        let generation = searchGeneration
        let end = displayedRows.last?.id
        isPaginating = true
        defer { isPaginating = false }
        while displayedRows.last?.id == end {
            let pending = unfetchedMatches.filter { !$0.value.uids.isEmpty }
            guard !pending.isEmpty else { return }
            for (folder, matches) in pending {
                let batch = Array(matches.uids.prefix(MailConstants.pageSize))
                do {
                    let more = try await session.use { client in
                        try await client.summaries(folder: folder, uids: batch, expectedUIDValidity: matches.uidValidity)
                    }
                    guard isCurrent(selection, epoch), generation == searchGeneration, let results = searchResults else { return }
                    unfetchedMatches[folder]?.uids = Array(matches.uids.dropFirst(batch.count))
                    let listed = Set(results.map(\.id))
                    let rows = more.filter { !$0.isDeleted }.map { MailListRow(folder: folder, summary: $0) }
                    searchResults = ordered(results + rows.filter { !listed.contains($0.id) })
                } catch MailClientError.folderChanged {
                    guard isCurrent(selection, epoch), generation == searchGeneration else { return }
                    unfetchedMatches[folder] = nil
                    searchResults?.removeAll { $0.folder == folder }
                    await recoverFromFolderChange(folder)
                    return
                } catch {
                    guard isCurrent(selection, epoch) else { return }
                    serverStatus = .failed
                    return
                }
            }
        }
    }

    func clearSearch() {
        searchGeneration += 1
        searchResults = nil
        searchUsedLocalFallback = false
    }

    private static func matches(_ summary: MailSummary, _ query: String) -> Bool {
        [summary.subject, summary.fromName, summary.fromAddress].contains {
            $0?.localizedCaseInsensitiveContains(query) == true
        }
    }

    func toggleRead(_ row: MailListRow) async {
        let seen = !row.summary.isSeen
        let folder = row.folder
        let uid = row.uid
        markSeenLocally(folder: folder, uid: uid, seen: seen)
        let validity = pages[folder]?.uidValidity
        do {
            try await session.use { client in
                try await client.setFlag(.seen, on: seen, folder: folder, uids: [uid],
                                         expectedUIDValidity: validity)
            }
        } catch MailClientError.folderChanged {
            markSeenLocally(folder: folder, uid: uid, seen: !seen)
            await recoverFromFolderChange(folder)
        } catch {
            markSeenLocally(folder: folder, uid: uid, seen: !seen)
        }
    }

    func markSeenLocally(folder: String, uid: UInt32, seen: Bool = true) {
        guard targets.contains(folder) else { return }
        if var page = pages[folder], let index = page.summaries.firstIndex(where: { $0.uid == uid }) {
            page.summaries[index].isSeen = seen
            pages[folder] = page
        }
        if let index = searchResults?.firstIndex(where: { $0.folder == folder && $0.uid == uid }) {
            searchResults?[index].summary.isSeen = seen
        }
        rebuildRows()
        persist(folder: folder)
    }

    func removeLocally(folder: String, uid: UInt32) {
        guard targets.contains(folder), var page = pages[folder] else { return }
        let removed = page.summaries.contains { $0.uid == uid }
        page.summaries.removeAll { $0.uid == uid }
        if removed { page.messageCount = max(0, page.messageCount - 1) }
        pages[folder] = page
        searchResults?.removeAll { $0.folder == folder && $0.uid == uid }
        rebuildRows()
        persist(folder: folder)
    }

    func startPolling(pollFirst: Bool = false) {
        isPaused = false
        if !warmDone, warmTask == nil { startWarmIfLoaded() }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            if pollFirst { await self?.pollOnce() }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(MailConstants.pagePollInterval))
                guard !Task.isCancelled, let self else { return }
                await self.pollOnce()
            }
        }
    }

    func stopPolling() {
        isPaused = true
        pollTask?.cancel()
        pollTask = nil
        cancelWarm()
        session.releaseSoon()
    }

    func resetForAccountChange() {
        pollTask?.cancel()
        pollTask = nil
        resetInMemoryState()
    }

    func waitForWarm() async {
        await warmTask?.value
    }

    func waitForCacheWrites() async {
        await pendingCacheWrite?.value
    }

    #if DEBUG
    func resetForServerChange() {
        stopPolling()
        resetInMemoryState()
        Task { await session.close() }
    }
    #endif

    private func resetInMemoryState() {
        accountEpoch += 1
        cancelWarm()
        warmDone = false
        folderRoles = [:]
        otherFolders = []
        pages = [:]
        cachePaintedFolders = []
        rows = []
        searchResults = nil
        searchUsedLocalFallback = false
        searchText = ""
        unreadOnly = false
        selection = .real(MailConstants.inbox)
        selectionWasChosen = false
        loadingSelection = nil
        loadState = .idle
        serverStatus = .unknown
        syncedAt = nil
        isRefreshing = false
        isPaginating = false
        sentCopyNotice = nil
    }

    func pollOnce() async {
        guard showsInbox, searchResults == nil else { return }
        let selection = self.selection
        let epoch = accountEpoch
        let inbox = MailConstants.inbox
        let folders = targets
        guard let statuses = try? await session.use({ client -> [String: MailboxStatusInfo] in
                  var result = [inbox: try await client.status(folder: inbox)]
                  for folder in folders where folder != inbox {
                      result[folder] = try? await client.status(folder: folder)
                  }
                  return result
              }),
              let status = statuses[inbox], isCurrent(selection, epoch), searchResults == nil else { return }
        let checkedAt = Date()
        let before = pages[inbox]
        if statuses.contains(where: { Self.hasUnshownMail($0.value, page: pages[$0.key]) }) {
            await load()
            guard isCurrent(selection, epoch) else { return }
            if let before, before.uidValidity == status.uidValidity {
                await prefetchArrivedBodies(after: before.summaries.map(\.uid).max() ?? 0)
            }
        }
        guard isCurrent(selection, epoch), !Self.hasUnshownMail(status, page: pages[inbox]) else { return }
        var movedUp: [String] = []
        for (folder, folderStatus) in statuses
        where !cachePaintedFolders.contains(folder) && !Self.hasUnshownMail(folderStatus, page: pages[folder]) {
            guard var page = pages[folder], page.fetchedAt.map({ $0 < checkedAt }) ?? true else { continue }
            page.fetchedAt = checkedAt
            pages[folder] = page
            movedUp.append(folder)
        }
        syncedAt = Self.syncedAt(of: targets.map { pages[$0] })
        await noteSeenByPage(status)
        guard isCurrent(selection, epoch) else { return }
        let cache = self.cache
        let writes = movedUp.compactMap { folder in
            pages[folder].map { page in
                let stored = Self.cachedCopy(of: page)
                return chainCacheWrite { cache.savePage(stored, wipeCount: $0) }
            }
        }
        for write in writes { await write.value }
    }

    nonisolated static func hasUnshownMail(_ status: MailboxStatusInfo, page: MailFolderPage?) -> Bool {
        guard let page, page.uidValidity == status.uidValidity, let shown = page.uidNext else { return true }
        return status.uidNext > shown
    }

    private func prefetchArrivedBodies(after previousNewest: UInt32) async {
        let epoch = accountEpoch
        let inbox = MailConstants.inbox
        guard loadState == .loaded, serverStatus == .ok, let page = pages[inbox] else { return }
        let validity = page.uidValidity
        let arrivals = page.summaries.map(\.uid).filter { $0 > previousNewest }
            .sorted(by: >).prefix(MailConstants.bodyPrefetchLimit)
        let cache = self.cache
        for uid in arrivals {
            guard !Task.isCancelled, epoch == accountEpoch else { return }
            let cached = await Task.detached { cache.loadDetail(folder: inbox, uidValidity: validity, uid: uid) }.value
            if cached != nil { continue }
            do {
                let detail = try await session.use { client in
                    try await client.detail(folder: inbox, uid: uid, expectedUIDValidity: validity, inlineImages: false)
                }
                guard epoch == accountEpoch else { return }
                chainCacheWrite { cache.saveDetail(detail, folder: inbox, uidValidity: validity, wipeCount: $0) }
            } catch let error as MailClientError where MailChecker.endsPrefetch(error) {
                return
            } catch {
                continue
            }
        }
    }

    private func startWarm() {
        warmTask?.cancel()
        warmDone = false
        var covered = Set(targets)
        let queue = MailFolderRole.allCases.compactMap { folderRoles[$0] }.filter { covered.insert($0).inserted }
        guard !queue.isEmpty else {
            warmTask = nil
            warmDone = true
            return
        }
        let epoch = accountEpoch
        let delay = warmDelay
        let cache = self.cache
        warmTask = Task { [weak self] in
            await delay()
            for folder in queue {
                guard !Task.isCancelled, let self, self.accountEpoch == epoch else { return }
                do {
                    var page = try await self.session.use { client in
                        try await client.page(folder: folder, olderThanSequence: nil, pageSize: MailConstants.warmPageSize)
                    }
                    page.fetchedAt = Date()
                    guard !Task.isCancelled, self.accountEpoch == epoch else { return }
                    if self.targets.contains(folder) { continue }
                    await self.chainCacheWrite { [page] wipeCount in
                        if Self.warmShouldWrite(page, over: cache.loadPage(folder: folder)) { cache.savePage(page, wipeCount: wipeCount) }
                    }.value
                } catch let error as MailClientError where MailChecker.endsPrefetch(error) {
                    return
                } catch {
                    continue
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.warmDone = true
            self.warmTask = nil
        }
    }

    private func startWarmIfLoaded() {
        guard !isPaused, loadState == .loaded, serverStatus == .ok else { return }
        startWarm()
    }

    private func cancelWarm() {
        warmTask?.cancel()
        warmTask = nil
    }

    nonisolated static func warmShouldWrite(_ page: MailFolderPage, over cached: MailFolderPage?) -> Bool {
        guard let cached, cached.uidValidity == page.uidValidity else { return true }
        return page.summaries.count >= cached.summaries.count
    }

    private func adoptDefaultSelection() -> Bool {
        guard !selectionWasChosen, selection != .allMail, showsAllMailChip else { return false }
        selection = .allMail
        return true
    }

    private func paintFromCache() async -> Bool {
        let cache = self.cache
        var painted = false
        for folder in targets where pages[folder] == nil {
            if let cached = await Self.cachedPage(cache: cache, folder: folder) {
                pages[folder] = cached
                cachePaintedFolders.insert(folder)
                painted = true
            }
        }
        if painted { rebuildRows() }
        return painted
    }

    private func rebuildRows() {
        var collected: [MailListRow] = []
        for folder in targets {
            guard let page = pages[folder] else { continue }
            collected += page.summaries.map { MailListRow(folder: folder, summary: $0) }
        }
        rows = selection == .allMail ? collected.sorted(by: Self.newestFirst) : collected
        syncedAt = Self.syncedAt(of: targets.map { pages[$0] })
    }

    nonisolated static func syncedAt(of pages: [MailFolderPage?]) -> Date? {
        var oldest: Date?
        for page in pages {
            guard let fetchedAt = page?.fetchedAt else { return nil }
            oldest = min(oldest ?? fetchedAt, fetchedAt)
        }
        return oldest
    }

    private func ordered(_ rows: [MailListRow]) -> [MailListRow] {
        selection == .allMail ? rows.sorted(by: Self.newestFirst) : rows.sorted { $0.uid > $1.uid }
    }

    nonisolated private static func newestFirst(_ lhs: MailListRow, _ rhs: MailListRow) -> Bool {
        let left = lhs.summary.date ?? .distantPast
        let right = rhs.summary.date ?? .distantPast
        if left != right { return left > right }
        if lhs.folder != rhs.folder { return lhs.folder < rhs.folder }
        return lhs.uid > rhs.uid
    }

    @discardableResult
    private func mergeFreshPage(_ fresh: MailFolderPage, folder: String) -> MailFolderPage {
        let previous = pages[folder]
        let hadPreviousPage = previous != nil
        let fromCache = cachePaintedFolders.remove(folder) != nil
        let existing = previous?.summaries ?? []
        let windowHidEverything = fresh.summaries.isEmpty && fresh.messageCount > 0
        let windowFloor = fresh.windowUIDs?.lowerBound ?? fresh.summaries.last?.uid
        let keptExisting: [MailSummary]
        if windowHidEverything {
            keptExisting = existing
        } else {
            keptExisting = windowFloor.map { floor in existing.filter { $0.uid < floor } } ?? []
        }
        let merged = (fresh.summaries + keptExisting).sorted { $0.uid > $1.uid }
        let oldestLoadedSequence: Int?
        if windowHidEverything, hadPreviousPage, !fromCache, !keptExisting.isEmpty {
            oldestLoadedSequence = previous?.oldestLoadedSequence
        } else if fresh.summaries.isEmpty {
            oldestLoadedSequence = fresh.oldestLoadedSequence
        } else if hadPreviousPage, !fromCache {
            oldestLoadedSequence = previous?.oldestLoadedSequence
        } else {
            oldestLoadedSequence = fresh.oldestLoadedSequence
        }
        let mergedPage = MailFolderPage(
            folder: folder, uidValidity: fresh.uidValidity, messageCount: fresh.messageCount,
            summaries: merged, oldestLoadedSequence: oldestLoadedSequence, uidNext: fresh.uidNext,
            fetchedAt: fresh.fetchedAt
        )
        pages[folder] = mergedPage
        return mergedPage
    }

    nonisolated private static func mergeOlderPage(_ older: MailFolderPage, into page: MailFolderPage) -> MailFolderPage {
        var merged = page
        if let window = older.windowUIDs ?? MailFolderPage.span(of: older.summaries.map(\.uid)) {
            let kept = page.summaries.filter { !window.contains($0.uid) }
            merged.summaries = (older.summaries + kept).sorted { $0.uid > $1.uid }
        }
        merged.oldestLoadedSequence = older.oldestLoadedSequence
        return merged
    }

    nonisolated private static func cachedCopy(of page: MailFolderPage) -> MailFolderPage {
        guard page.summaries.count > MailConstants.cachedPageRows else { return page }
        var copy = page
        copy.summaries = Array(page.summaries.prefix(MailConstants.cachedPageRows))
        let newestWindowStart = page.messageCount - MailConstants.pageSize + 1
        copy.oldestLoadedSequence = newestWindowStart > 1 ? newestWindowStart : nil
        return copy
    }

    private func walkBackToVisibleMail(from start: MailFolderPage, folder: String) async -> MailFolderPage {
        var current = start
        var fetched = 0
        let selection = self.selection
        let epoch = accountEpoch
        while current.summaries.isEmpty, let cursor = current.oldestLoadedSequence,
              fetched < MailConstants.emptyWindowWalkbackPages {
            fetched += 1
            guard let older = try? await session.use({ client in
                try await client.page(folder: folder, olderThanSequence: cursor, pageSize: MailConstants.pageSize)
            }) else { break }
            guard isCurrent(selection, epoch), older.uidValidity == current.uidValidity else { break }
            current = MailFolderPage(
                folder: current.folder, uidValidity: current.uidValidity, messageCount: current.messageCount,
                summaries: older.summaries.sorted { $0.uid > $1.uid },
                oldestLoadedSequence: older.oldestLoadedSequence, uidNext: current.uidNext,
                fetchedAt: current.fetchedAt
            )
            pages[folder] = current
            rebuildRows()
        }
        return current
    }

    func recoverFromFolderChange(_ folder: String) async {
        await dropFolder(folder)
        guard targets.contains(folder) else { return }
        pages[folder] = nil
        rebuildRows()
        await load()
    }

    private func persist(folder: String) {
        guard let page = pages[folder].map(Self.cachedCopy(of:)) else { return }
        let cache = self.cache
        chainCacheWrite { cache.savePage(page, wipeCount: $0) }
    }

    nonisolated private static func cachedPage(cache: MailCache, folder: String) async -> MailFolderPage? {
        await Task.detached { cache.loadPage(folder: folder) }.value
    }

    private func save(_ page: MailFolderPage) async {
        let cache = self.cache
        let stored = Self.cachedCopy(of: page)
        await chainCacheWrite { cache.savePage(stored, wipeCount: $0) }.value
    }

    private func dropFolder(_ folder: String) async {
        let cache = self.cache
        await chainCacheWrite { _ in cache.dropFolder(folder) }.value
    }

    @discardableResult
    private func chainCacheWrite(_ operation: @escaping @Sendable (_ wipeCount: Int) -> Void) -> Task<Void, Never> {
        let previous = pendingCacheWrite
        let wipeCount = cache.wipeCount
        let task = Task.detached {
            _ = await previous?.value
            operation(wipeCount)
        }
        pendingCacheWrite = task
        return task
    }
}
#endif
