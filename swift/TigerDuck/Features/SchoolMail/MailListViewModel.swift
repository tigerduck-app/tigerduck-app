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
    private(set) var selectedFolder = MailConstants.inbox
    private(set) var summaries: [MailSummary] = []
    private(set) var loadState: LoadState = .idle
    private(set) var serverStatus: ServerStatus = .unknown
    private(set) var isRefreshing = false
    private(set) var isPaginating = false
    private(set) var searchResults: [MailSummary]?
    private(set) var searchUsedLocalFallback = false
    var searchText = ""
    var unreadOnly = false

    @ObservationIgnored let session: MailPageSession
    @ObservationIgnored private let cache: MailCache
    @ObservationIgnored private let runPageCheck: (any MailClient) async -> MailCheckOutcome
    @ObservationIgnored private var page: MailFolderPage?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// The folder a `load()` call currently in flight is fetching, so a second call for that
    /// same folder (e.g. a pull-to-refresh landing while the 60 s poll's own reload is still
    /// running) doesn't issue a redundant `listFolders`/`page` pair on the one serialized
    /// connection. A call for a *different* folder (the user switching chips mid-load) is
    /// never blocked by this — it proceeds immediately, and whichever fetch turns out to be
    /// stale by the time it returns is discarded by the `folder == selectedFolder` checks
    /// below rather than by being refused up front.
    @ObservationIgnored private var loadingFolder: String?
    /// The tail of the cache-write chain — see `chainCacheWrite`.
    @ObservationIgnored private var pendingCacheWrite: Task<Void, Never>?

    init(
        session: MailPageSession? = nil,
        cache: MailCache? = nil,
        runPageCheck: @escaping (any MailClient) async -> MailCheckOutcome = { await MailChecker.shared.check(trigger: .page, using: $0) }
    ) {
        // Both defaults are resolved here, in the init's own MainActor-isolated body, rather
        // than in the default-parameter expressions above: a default-parameter expression is
        // evaluated outside the initializer's own isolation, so `MailPageSession()` (a
        // MainActor-isolated init) and `MailAccountManager.shared` (a MainActor-isolated
        // static property) can't be reached from there without a warning under Swift 6 mode.
        self.session = session ?? MailPageSession()
        self.cache = cache ?? MailAccountManager.shared.cache
        self.runPageCheck = runPageCheck
    }

    var displayedSummaries: [MailSummary] {
        let base = searchResults ?? summaries
        return unreadOnly ? base.filter { !$0.isSeen } : base
    }

    // MARK: Loading

    /// Paints the cached list first, then refreshes the newest page from the server, merging
    /// the refresh into whatever's already loaded rather than replacing it (§ pagination):
    /// new mail is added, and anything the user already paginated further in than this
    /// first-page refresh covers is kept.
    func load() async {
        let folder = selectedFolder
        guard loadingFolder != folder else { return }
        loadingFolder = folder
        defer { if loadingFolder == folder { loadingFolder = nil } }

        let cache = self.cache
        if page == nil, let cached = await Self.cachedPage(cache: cache, folder: folder) {
            apply(cached)
            loadState = .loaded
        } else if summaries.isEmpty {
            loadState = .loading
        }
        isRefreshing = true
        // Only clear the shared (not per-folder) `isRefreshing`/status-dot state if this call
        // is still the one whose folder is on screen and whose in-flight claim on
        // `loadingFolder` nothing newer has since taken over — otherwise a slow load for a
        // folder the user has since left (or already superseded by a newer load) could stop
        // the spinner or flip the dot red while a still-relevant load is genuinely in flight.
        defer { if folder == selectedFolder, loadingFolder == folder { isRefreshing = false } }
        let needsFolders = folderRoles.isEmpty
        do {
            let (resolvedFolders, fresh) = try await session.use { client -> ([String]?, MailFolderPage) in
                let folders = needsFolders ? try await client.listFolders() : nil
                let page = try await client.page(folder: folder, olderThanSequence: nil, pageSize: MailConstants.pageSize)
                return (folders, page)
            }
            if let resolvedFolders {
                folderRoles = MailFolderMap.resolve(available: resolvedFolders)
                otherFolders = MailFolderMap.otherFolders(available: resolvedFolders)
            }
            guard folder == selectedFolder else { return }
            if let previous = page, previous.uidValidity != fresh.uidValidity {
                await dropFolder(folder)
                page = nil
                summaries = []
            }
            var merged = mergeFreshPage(fresh)
            if merged.summaries.isEmpty, merged.messageCount > 0 {
                merged = await walkBackToVisibleMail(from: merged, folder: folder)
            }
            guard folder == selectedFolder else { return }
            await save(merged)
            serverStatus = .ok
            loadState = .loaded
        } catch {
            guard folder == selectedFolder else { return }
            serverStatus = .failed
            loadState = summaries.isEmpty ? .failed(MailAccountManager.LoginError(error).message) : .loaded
        }
    }

    func loadMoreIfNeeded(after summary: MailSummary) async {
        guard searchResults == nil, !isPaginating, summary.uid == displayedSummaries.last?.uid,
              let older = page?.oldestLoadedSequence else { return }
        isPaginating = true
        defer { isPaginating = false }
        let folder = selectedFolder
        do {
            let next = try await session.use { client in
                try await client.page(folder: folder, olderThanSequence: older, pageSize: MailConstants.pageSize)
            }
            guard folder == selectedFolder else { return }
            let known = Set(summaries.map(\.uid))
            summaries += next.summaries.filter { !known.contains($0.uid) }
            page?.summaries = summaries
            page?.oldestLoadedSequence = next.oldestLoadedSequence
        } catch MailClientError.folderChanged {
            await recoverFromFolderChange(folder)
        } catch {
            guard folder == selectedFolder else { return }
            serverStatus = .failed
        }
    }

    func select(folder: String) async {
        guard folder != selectedFolder else { return }
        selectedFolder = folder
        page = nil
        summaries = []
        searchResults = nil
        searchUsedLocalFallback = false
        await load()
    }

    // MARK: Search

    /// Server-side search in the current folder; if the server refuses (or is unreachable),
    /// only the loaded mail is searched and the list says so (§8.3).
    func submitSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            clearSearch()
            return
        }
        let folder = selectedFolder
        do {
            let found = try await session.use { client -> [MailSummary] in
                let matches = try await client.search(folder: folder, query: query)
                let newest = Array(matches.sorted(by: >).prefix(MailConstants.pageSize))
                return try await client.summaries(folder: folder, uids: newest)
            }
            guard folder == selectedFolder else { return }
            searchResults = found.filter { !$0.isDeleted }.sorted { $0.uid > $1.uid }
            searchUsedLocalFallback = false
        } catch {
            guard folder == selectedFolder else { return }
            if (error as? MailClientError) != .searchUnsupported {
                serverStatus = .failed
            }
            searchResults = summaries.filter { Self.matches($0, query) }
            searchUsedLocalFallback = true
        }
    }

    func clearSearch() {
        searchResults = nil
        searchUsedLocalFallback = false
    }

    private static func matches(_ summary: MailSummary, _ query: String) -> Bool {
        [summary.subject, summary.fromName, summary.fromAddress].contains {
            $0?.localizedCaseInsensitiveContains(query) == true
        }
    }

    // MARK: Changes

    func toggleRead(_ summary: MailSummary) async {
        let seen = !summary.isSeen
        let folder = selectedFolder
        markSeenLocally(folder: folder, uid: summary.uid, seen: seen)
        let validity = page?.uidValidity
        do {
            try await session.use { client in
                try await client.setFlag(.seen, on: seen, folder: folder, uids: [summary.uid],
                                         expectedUIDValidity: validity)
            }
        } catch MailClientError.folderChanged {
            markSeenLocally(folder: folder, uid: summary.uid, seen: !seen)
            await recoverFromFolderChange(folder)
        } catch {
            markSeenLocally(folder: folder, uid: summary.uid, seen: !seen)
        }
    }

    /// Called by the message screen after it marks a mail read or unread, and by `toggleRead`
    /// for its own optimistic update and revert.
    ///
    /// `folder` is not decoration: a UID is only unique within its own folder, so a call that
    /// started against one folder must not touch the list once the user (or a deep link) has
    /// switched to another. Without the guard a same-UID row of a *different* message gets
    /// flipped here and written to that folder's cache by `persistPage()`.
    func markSeenLocally(folder: String, uid: UInt32, seen: Bool = true) {
        guard folder == selectedFolder else { return }
        if let index = summaries.firstIndex(where: { $0.uid == uid }) { summaries[index].isSeen = seen }
        if let index = searchResults?.firstIndex(where: { $0.uid == uid }) { searchResults?[index].isSeen = seen }
        persistPage()
    }

    /// Called by the message screen after it moves or deletes a mail. Guarded on `folder` for
    /// the same reason `markSeenLocally` is — here the stale call would remove a different
    /// folder's row outright and decrement that folder's `messageCount`.
    func removeLocally(folder: String, uid: UInt32) {
        guard folder == selectedFolder else { return }
        let removed = summaries.contains { $0.uid == uid }
        summaries.removeAll { $0.uid == uid }
        searchResults?.removeAll { $0.uid == uid }
        if removed, let count = page?.messageCount { page?.messageCount = max(0, count - 1) }
        persistPage()
    }

    // MARK: Polling (60 s while the page is visible)

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(MailConstants.pagePollInterval))
                guard !Task.isCancelled, let self else { return }
                await self.pollOnce()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        session.releaseSoon()
    }

    func pollOnce() async {
        let check = runPageCheck
        guard let outcome = try? await session.use({ client in await check(client) }) else { return }
        // `.baselineReset` reloads for the same reason `.newMail` does: INBOX's UIDVALIDITY
        // changed, so every UID on screen belongs to a generation the server has thrown away.
        // Without this the list keeps painting the old generation (and answering taps with
        // `folderChanged`) until something else happens to force a reload.
        switch outcome {
        case .newMail, .baselineReset:
            guard selectedFolder == MailConstants.inbox, searchResults == nil else { return }
            await load()
        default:
            return
        }
    }

    // MARK: Internals

    private func apply(_ page: MailFolderPage) {
        self.page = page
        summaries = page.summaries
    }

    /// Merges a freshly fetched first page into whatever's already loaded for its folder,
    /// instead of replacing it (a poll- or pull-to-refresh-triggered reload must never
    /// discard mail the user already paginated further in than the first page): every UID in
    /// `fresh` wins (it's the more current copy — flags included). An existing entry survives
    /// only when it's *older* than everything `fresh` covers (its UID is below
    /// `fresh.summaries.last?.uid`, the bottom of the fresh page's window) — anything inside
    /// that window that `fresh` no longer carries was expunged, moved or flagged `\Deleted`
    /// server-side (webmail, another device) and must disappear here too, not be kept forever
    /// and written back to the cache. An empty `fresh` page for a folder the server says is
    /// genuinely empty (`messageCount == 0`) keeps nothing at all.
    ///
    /// An empty `fresh` page for a folder that is **not** empty is the exception, and the reason
    /// this isn't simply "empty means empty": `page()` drops every `\Deleted` row, so a folder
    /// whose newest 50 messages are all flagged returns no summaries while still holding
    /// hundreds of messages. That is exactly the state a partly failed delete manufactures (an
    /// unclaimed `\Deleted` UID blocks every later EXPUNGE, so flagged mail piles up), and it is
    /// reachable on this app's own after 50 deletes. Dropping everything there blanks the list,
    /// `load()` then persists that empty page over the cache, and with no rows left nothing
    /// drives pagination — the user is left with an empty mailbox and no way back to mail the
    /// server still has. A transient empty read has the same shape and the same cure. So the
    /// existing rows are kept in that case (they may be stale, and the next refresh whose window
    /// reaches them corrects them — the same self-healing the window floor already relies on),
    /// and `load()` walks further back when there was nothing to keep.
    ///
    /// The pagination cursor (`oldestLoadedSequence`) mirrors the same rule: it's kept from
    /// the existing page only when something from that existing page actually survived the
    /// merge (a first-page refresh alone knows nothing about how much further the user had
    /// paginated, and sequence numbers of messages that already existed are stable across new
    /// mail arriving — IMAP only appends — so the old cursor still points to the right place
    /// in that case); an empty fresh page otherwise takes fresh's own cursor.
    @discardableResult
    private func mergeFreshPage(_ fresh: MailFolderPage) -> MailFolderPage {
        let hadPreviousPage = page?.folder == fresh.folder
        let existing = hadPreviousPage ? summaries : []
        let windowHidEverything = fresh.summaries.isEmpty && fresh.messageCount > 0
        let windowFloor = fresh.summaries.last?.uid
        let keptExisting: [MailSummary]
        if windowHidEverything {
            keptExisting = existing
        } else {
            keptExisting = windowFloor.map { floor in existing.filter { $0.uid < floor } } ?? []
        }
        let merged = (fresh.summaries + keptExisting).sorted { $0.uid > $1.uid }
        let oldestLoadedSequence: Int?
        if windowHidEverything, hadPreviousPage, !keptExisting.isEmpty {
            oldestLoadedSequence = page?.oldestLoadedSequence
        } else if fresh.summaries.isEmpty {
            oldestLoadedSequence = fresh.oldestLoadedSequence
        } else if hadPreviousPage {
            oldestLoadedSequence = page?.oldestLoadedSequence
        } else {
            oldestLoadedSequence = fresh.oldestLoadedSequence
        }
        let mergedPage = MailFolderPage(
            folder: fresh.folder, uidValidity: fresh.uidValidity, messageCount: fresh.messageCount,
            summaries: merged, oldestLoadedSequence: oldestLoadedSequence
        )
        page = mergedPage
        summaries = merged
        return mergedPage
    }

    /// Pagination hangs off the last row's `.task` (`SchoolMailView`), so a list with no rows can
    /// never fetch further back on its own — and `load()` always asks for the newest window, so
    /// every refresh would come back just as empty. When the merge leaves nothing while the
    /// server says the folder still holds mail, walk the cursor back here instead, a bounded
    /// number of pages, until something the server still shows turns up.
    private func walkBackToVisibleMail(from start: MailFolderPage, folder: String) async -> MailFolderPage {
        var current = start
        var fetched = 0
        while current.summaries.isEmpty, let cursor = current.oldestLoadedSequence,
              fetched < MailConstants.emptyWindowWalkbackPages {
            fetched += 1
            guard let older = try? await session.use({ client in
                try await client.page(folder: folder, olderThanSequence: cursor, pageSize: MailConstants.pageSize)
            }) else { break }
            // A folder switch, or the folder being recreated under us: either way this walk has
            // nothing left to say, and the load that follows recovers properly.
            guard folder == selectedFolder, older.uidValidity == current.uidValidity else { break }
            current = MailFolderPage(
                folder: current.folder, uidValidity: current.uidValidity, messageCount: current.messageCount,
                summaries: older.summaries.sorted { $0.uid > $1.uid },
                oldestLoadedSequence: older.oldestLoadedSequence
            )
            page = current
            summaries = current.summaries
        }
        return current
    }

    /// A folder's UIDVALIDITY no longer matches what a list operation was built from (spec
    /// §8.3): its cached page — and any cached bodies — are meaningless now, so they're
    /// dropped, and the first page is reloaded fresh from the server.
    ///
    /// Not `private`: the message screen's own move/delete can hit the very same
    /// `MailClientError.folderChanged` on the connection this list view model shares, and
    /// routes its recovery through here too (via `onFolderChanged`) — never through a
    /// `cache.dropFolder` call of its own, which could race and be undone by this type's queued
    /// cache-write chain (`chainCacheWrite`) landing after it (fix round 1, important 2).
    func recoverFromFolderChange(_ folder: String) async {
        await dropFolder(folder)
        guard folder == selectedFolder else { return }
        page = nil
        summaries = []
        await load()
    }

    /// `markSeenLocally`/`removeLocally` are synchronous (the message screen calls them
    /// without awaiting), so the disk write can't be awaited here — it's queued through
    /// `chainCacheWrite` instead, fire-and-forget.
    private func persistPage() {
        page?.summaries = summaries
        guard let page else { return }
        let cache = self.cache
        chainCacheWrite { cache.savePage(page) }
    }

    // MARK: Cache (off the main actor — `MailCache` does synchronous disk I/O)

    nonisolated private static func cachedPage(cache: MailCache, folder: String) async -> MailFolderPage? {
        await Task.detached { cache.loadPage(folder: folder) }.value
    }

    private func save(_ page: MailFolderPage) async {
        let cache = self.cache
        await chainCacheWrite { cache.savePage(page) }.value
    }

    private func dropFolder(_ folder: String) async {
        let cache = self.cache
        await chainCacheWrite { cache.dropFolder(folder) }.value
    }

    /// Every cache *write* in this type — `persistPage()`'s fire-and-forget save, `load()`'s
    /// save of a freshly fetched page, `recoverFromFolderChange`'s drop — is queued through
    /// here, in the exact order it was requested. Without this, an earlier write that happens
    /// to take longer (e.g. a toggle's fire-and-forget persist) could still be running when a
    /// later one starts (a drop that followed it moments later, say), and finish *after* it —
    /// silently resurrecting on disk exactly what the later write meant to replace or remove.
    @discardableResult
    private func chainCacheWrite(_ operation: @escaping @Sendable () -> Void) -> Task<Void, Never> {
        let previous = pendingCacheWrite
        let task = Task.detached {
            _ = await previous?.value
            operation()
        }
        pendingCacheWrite = task
        return task
    }
}
#endif
