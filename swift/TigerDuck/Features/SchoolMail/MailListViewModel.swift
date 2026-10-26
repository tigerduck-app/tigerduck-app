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
    @ObservationIgnored private var indexLookup: Task<(uidValidity: UInt32, uids: [UInt32])?, Never>?
    /// The query of the search under way or shown; empty when there is none.
    @ObservationIgnored private var searchQuery = ""
    /// The search whose results `searchResults` shows.
    @ObservationIgnored private var resultsGeneration = -1
    @ObservationIgnored private var searchIsBehind = false
    @ObservationIgnored private var searchCatchUp: Task<Void, Never>?
    @ObservationIgnored private let catchUpDelay: @Sendable () async -> Void
    @ObservationIgnored private var warmTask: Task<Void, Never>?
    @ObservationIgnored private var warmDone = false
    @ObservationIgnored private var isPaused = false
    @ObservationIgnored private let warmDelay: @Sendable () async -> Void
    @ObservationIgnored private let indexer: MailIndexer
    @ObservationIgnored nonisolated(unsafe) private var signOutObserver: (any NSObjectProtocol)?
    @ObservationIgnored private let signOutEvents: NotificationCenter

    init(
        session: MailPageSession? = nil,
        cache: MailCache? = nil,
        noteSeenByPage: ((MailboxStatusInfo) async -> Void)? = nil,
        signOutEvents: NotificationCenter = .default,
        warmDelay: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: MailConstants.warmStartDelay) },
        catchUpDelay: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: MailConstants.searchCatchUpInterval) }
    ) {
        // Resolved in the body, not the parameter list: a default-argument expression runs outside
        // the init's MainActor isolation, where `MailPageSession()` and `MailAccountManager.shared`
        // warn in Swift 6 mode and the checker's closure would be isolated to `MailChecker`.
        let session = session ?? MailPageSession()
        let cache = cache ?? MailAccountManager.shared.cache
        self.session = session
        self.cache = cache
        self.noteSeenByPage = noteSeenByPage ?? { await MailChecker.shared.noteSeenByPage($0) }
        self.signOutEvents = signOutEvents
        self.warmDelay = warmDelay
        self.catchUpDelay = catchUpDelay
        // Starts after the warm's delay too, so the refresh that follows a paint goes first.
        indexer = MailIndexer(session: session, cache: cache, startDelay: warmDelay)
        indexer.onFill = { [weak self] folder in self?.indexDidFill(folder) }
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

    var targets: [String] { selection.targets(roles: folderRoles, others: otherFolders) }

    var showsAllMailChip: Bool {
        MailFolderSelection.allMail.targets(roles: folderRoles, others: otherFolders).count > 1
    }

    var showsInbox: Bool { targets.contains(MailConstants.inbox) }

    /// The status dot's text, which says OK only once the search index is complete: until then,
    /// and while a pass downloads, it counts the index's mail, or says it is syncing before the
    /// first count. A failed server shows its failure first.
    var statusText: String {
        guard serverStatus == .ok, isIndexBusy else { return SyncStatusDot.statusText(serverStatus) }
        return indexer.progress?.text() ?? String(localized: "sync_status_syncing")
    }

    /// Whether the status dot spins: a load, or a pass with mail to download.
    var isSyncing: Bool {
        isRefreshing || (serverStatus == .ok && indexer.isRunning && indexer.progress?.total != 0)
    }

    /// An index that is already current shows nothing rather than spinning at 0/0.
    private var isIndexBusy: Bool {
        !indexer.isComplete || (indexer.isRunning && indexer.progress?.total != 0)
    }

    // MARK: Loading

    /// Paints each covered folder's cached page first, then refreshes the newest page of each
    /// from the server. The refresh is merged into what is already loaded, not swapped in: new
    /// mail is added, and mail the user paginated to beyond this first page is kept.
    ///
    /// One page per real folder: one round trip for an ordinary folder, one per covered folder
    /// for All mail, however far the merged list has been scrolled. That bound is why the merged
    /// view refreshes only the newest page per folder: Mail2000 caps connections and starts
    /// answering "The mail server is busy" under load.
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
            // A folder that fails leaves the others' pages; a lost connection, a busy server or a
            // rejected password stops at that folder, as each one after it would fail the same way.
            typealias Fetched = (pages: [(String, MailFolderPage)], failure: MailClientError?)
            let fetched = try await session.use { client -> Fetched in
                var pages: [(String, MailFolderPage)] = []
                var failure: MailClientError?
                for folder in folders {
                    do {
                        pages.append((folder, try await client.page(folder: folder, olderThanSequence: nil,
                                                                    pageSize: MailConstants.pageSize)))
                    } catch let error as MailClientError {
                        failure = error
                        if MailChecker.endsPrefetch(error) { break }
                    }
                }
                return (pages, failure)
            }
            guard isCurrent(selection, epoch) else { return }
            let fetchedAt = Date()
            for (folder, page) in fetched.pages {
                var fresh = page
                fresh.fetchedAt = fetchedAt
                if pages[folder]?.uidNext != fresh.uidNext { indexer.noteNewMail() }
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
            if let failure = fetched.failure { throw failure }
            serverStatus = .ok
            loadState = .loaded
            startIndexIfLoaded()
        } catch {
            guard isCurrent(selection, epoch) else { return }
            serverStatus = .failed
            loadState = rows.isEmpty ? .failed(MailAccountManager.LoginError(error).message) : .loaded
        }
    }

    /// A load the user asked for (the screen opening, a pull, Retry, the compose sheet closing),
    /// with the warm stopped first and started again once the list is up.
    ///
    /// The warm shares the one connection and `AsyncSerialLock` is FIFO, so a running warm would
    /// queue this load behind every folder still waiting. A page in flight cannot be aborted
    /// (SwiftMail commands run to completion), so this waits at most one page, and the warm's
    /// start delay makes even that unlikely. Without the restart the first pull would end warming
    /// for the visit. The 60 s poll calls `load()` alone: re-warming each minute is not its job.
    func refresh(forcingIndex: Bool = false) async {
        cancelWarm()
        await load()
        // A pull starts the search index's download at once, however recent the last one.
        if forcingIndex { startIndexIfLoaded(force: true) }
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
        clearSearch()
        cancelWarm()
        await load()
        // The query stays in the field, so the new mailbox shows its results, not its plain list.
        if self.selection == selection, !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await submitSearch()
        }
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
        supersedeSearch()
        searchQuery = query
        let generation = searchGeneration
        var found: [MailListRow] = []
        var unfetched: [String: (uidValidity: UInt32, uids: [UInt32])] = [:]
        var usedFallback = false
        var serverFailed = false
        var recreated: [String] = []
        for folder in targets {
            guard !Task.isCancelled, generation == searchGeneration else { return }
            let matched = await matchingUIDs(in: folder, query: query)
            guard !Task.isCancelled, isCurrent(selection, epoch), generation == searchGeneration else { return }
            guard let matched, !matched.uids.isEmpty else { continue }
            let validity = matched.uidValidity
            let newest = Array(matched.uids.prefix(MailConstants.pageSize))
            do {
                let summaries = try await session.use { client in
                    try await client.summaries(folder: folder, uids: newest, expectedUIDValidity: validity)
                }
                guard isCurrent(selection, epoch), generation == searchGeneration else { return }
                found += summaries.filter { !$0.isDeleted }.map { MailListRow(folder: folder, summary: $0) }
                unfetched[folder] = (validity, Array(matched.uids.dropFirst(newest.count)))
            } catch MailClientError.folderChanged {
                guard isCurrent(selection, epoch) else { return }
                recreated.append(folder)
            } catch {
                guard isCurrent(selection, epoch) else { return }
                serverFailed = true
                let uids = Set(matched.uids)
                found += (pages[folder]?.summaries ?? []).filter { uids.contains($0.uid) }
                    .map { MailListRow(folder: folder, summary: $0) }
                usedFallback = true
            }
        }
        guard isCurrent(selection, epoch), generation == searchGeneration else { return }
        if serverFailed { serverStatus = .failed }
        searchResults = ordered(found)
        resultsGeneration = generation
        unfetchedMatches = unfetched
        searchUsedLocalFallback = usedFallback
        for folder in recreated { await recoverFromFolderChange(folder) }
        if displayedRows.isEmpty { await loadMoreSearchResults() }
        guard generation == searchGeneration else { return }
        if searchIsBehind { scheduleSearchCatchUp() }
        // A folder the index has not caught up with is downloaded now; its matches join as they arrive.
        if targets.contains(where: { !indexer.isIndexed($0) }) { startIndexIfLoaded(force: true) }
    }

    /// `folder`'s mail that matches `query`, newest first: the index's, and the loaded mail's, which
    /// may have arrived since the index last caught up. Nil when neither knows the folder.
    private func matchingUIDs(in folder: String, query: String) async -> (uidValidity: UInt32, uids: [UInt32])? {
        let lookup = Task.detached { [index = cache.searchIndex] in index.search(folder: folder, query: query) }
        indexLookup = lookup
        let indexed = await lookup.value
        let page = pages[folder]
        guard let validity = page?.uidValidity ?? indexed?.uidValidity else { return nil }
        var matched = Set(indexed?.uidValidity == validity ? indexed?.uids ?? [] : [])
        matched.formUnion((page?.summaries ?? []).filter { Self.matches($0, query) }.map(\.uid))
        return (validity, matched.sorted(by: >))
    }

    /// A pass that fills a folder the search covers adds its new matches to the results, at most
    /// once per `catchUpDelay`, so the last fill's are added after the pass ends.
    private func indexDidFill(_ folder: String) {
        guard !searchQuery.isEmpty, targets.contains(folder) else { return }
        searchIsBehind = true
        if resultsGeneration == searchGeneration { scheduleSearchCatchUp() }
    }

    private func scheduleSearchCatchUp() {
        guard searchCatchUp == nil else { return }
        let generation = searchGeneration
        let delay = catchUpDelay
        searchCatchUp = Task { [weak self] in
            await delay()
            while let self, !Task.isCancelled, generation == self.searchGeneration, self.searchIsBehind {
                self.searchIsBehind = false
                await self.catchUpSearch()
                await delay()
            }
            guard let self, !Task.isCancelled, generation == self.searchGeneration else { return }
            self.searchCatchUp = nil
        }
    }

    /// Adds the matches the index gained since the search ran, leaving the listed rows in place:
    /// a folder's matches newer than its oldest listed row are fetched now, with older ones only
    /// to fill its first page, and the rest wait for the end of the list.
    private func catchUpSearch() async {
        let query = searchQuery
        let selection = self.selection
        let epoch = accountEpoch
        let generation = searchGeneration
        for folder in targets {
            let matched = await matchingUIDs(in: folder, query: query)
            guard isCurrent(selection, epoch), generation == searchGeneration, let results = searchResults else { return }
            guard let matched, unfetchedMatches[folder].map({ $0.uidValidity == matched.uidValidity }) ?? true else {
                continue
            }
            let listed = Set(results.filter { $0.folder == folder }.map(\.uid))
            let waiting = matched.uids.filter { !listed.contains($0) }
            let oldestListed = listed.min() ?? .max
            let wanted = waiting.prefix { $0 > oldestListed }.count + max(0, MailConstants.pageSize - listed.count)
            let batch = Array(waiting.prefix(min(wanted, MailConstants.pageSize)))
            unfetchedMatches[folder] = (matched.uidValidity, waiting)
            guard !batch.isEmpty else { continue }
            do {
                let summaries = try await session.use { client in
                    try await client.summaries(folder: folder, uids: batch, expectedUIDValidity: matched.uidValidity)
                }
                guard isCurrent(selection, epoch), generation == searchGeneration, let current = searchResults else { return }
                unfetchedMatches[folder]?.uids.removeAll { batch.contains($0) }
                let shown = Set(current.map(\.id))
                let rows = summaries.filter { !$0.isDeleted }.map { MailListRow(folder: folder, summary: $0) }
                    .filter { !shown.contains($0.id) }
                if !rows.isEmpty { searchResults = ordered(current + rows) }
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
        supersedeSearch()
        searchQuery = ""
        searchResults = nil
        searchUsedLocalFallback = false
    }

    /// Also stops the scan of the index under way, which holds the lock its download writes under.
    private func supersedeSearch() {
        searchGeneration += 1
        indexLookup?.cancel()
        searchCatchUp?.cancel()
        searchCatchUp = nil
        searchIsBehind = false
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
        startIndexIfLoaded()
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            if pollFirst { await self?.pollOnce() }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(MailConstants.pagePollInterval))
                guard !Task.isCancelled, let self else { return }
                await self.pollOnce()
                // A pass Low Data Mode paused, or one waiting out a failure, picks up here.
                self.startIndexIfLoaded()
            }
        }
    }

    func stopPolling() {
        isPaused = true
        pollTask?.cancel()
        pollTask = nil
        cancelWarm()
        indexer.stop()
        session.releaseSoon()
    }

    func resetForAccountChange() {
        pollTask?.cancel()
        pollTask = nil
        resetInMemoryState()
    }

    func waitForWarm() async { await warmTask?.value }

    func waitForIndex() async { await indexer.waitForPass() }

    func waitForSearchCatchUp() async { await searchCatchUp?.value }

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
        indexer.reset()
        warmDone = false
        folderRoles = [:]
        otherFolders = []
        pages = [:]
        cachePaintedFolders = []
        rows = []
        clearSearch()
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

    // MARK: Warm

    /// Warms the folders the user is not looking at, so a chip tap paints from cache, not a
    /// spinner: the role folders in chip order, minus what the selection shows, at
    /// `MailConstants.warmPageSize` rows each. One at a time on the page's own connection, since
    /// Mail2000 caps connections and answers "server busy" under load, and the screen being
    /// read would pay for a fan-out. Silent: it writes only the cache, never `loadState`,
    /// `serverStatus`, `rows` or `pages`, and never shortens a cache the user paged further into
    /// (`warmShouldWrite`). Failures are swallowed, except a lost connection, which stops the
    /// queue rather than logging in again per folder: NTUST counts failed logins towards a lockout.
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
            // Cancelling cannot abort a page already on the wire, so the only way to spare the
            // refresh that follows a paint straight away is for the warm not to have started yet.
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

    /// Inbox and Sent first: most searches look there.
    private func startIndexIfLoaded(force: Bool = false) {
        guard !isPaused, loadState == .loaded, serverStatus == .ok, !folderRoles.isEmpty else { return }
        let roles = MailFolderRole.allCases.compactMap { folderRoles[$0] }
        indexer.startIfDue(folders: roles + otherFolders.filter { !roles.contains($0) }, force: force)
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
