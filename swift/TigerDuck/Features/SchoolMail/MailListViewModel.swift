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
    /// The merged list, newest first. Every entry carries the real folder it came from — see
    /// `MailListRow` — and every action a row leads to addresses *that* folder, never
    /// `selection`, which for 所有信件 is not a folder at all.
    private(set) var rows: [MailListRow] = []
    private(set) var loadState: LoadState = .idle
    private(set) var serverStatus: ServerStatus = .unknown
    private(set) var isRefreshing = false
    private(set) var isPaginating = false
    private(set) var searchResults: [MailListRow]?
    private(set) var searchUsedLocalFallback = false
    var searchText = ""
    var unreadOnly = false

    @ObservationIgnored let session: MailPageSession
    @ObservationIgnored private let cache: MailCache
    @ObservationIgnored private let runPageCheck: (any MailClient) async -> MailCheckOutcome
    /// One page per *real* folder, keyed by folder name. 所有信件 holds two of them and merges
    /// them at read time (`rebuildRows`); there is no merged page and nothing new on disk, so
    /// the existing per-folder cache files and their UIDVALIDITY pins keep meaning exactly what
    /// they meant before.
    @ObservationIgnored private var pages: [String: MailFolderPage] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// The selection a `load()` call currently in flight is fetching, so a second call for that
    /// same selection (e.g. a pull-to-refresh landing while the 60 s poll's own reload is still
    /// running) doesn't issue a redundant `listFolders`/`page` pair on the one serialized
    /// connection. A call for a *different* selection (the user switching chips mid-load) is
    /// never blocked by this — it proceeds immediately, and whichever fetch turns out to be
    /// stale by the time it returns is discarded by the `selection == self.selection` checks
    /// below rather than by being refused up front.
    @ObservationIgnored private var loadingSelection: MailFolderSelection?
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

    var displayedRows: [MailListRow] {
        let base = searchResults ?? rows
        return unreadOnly ? base.filter { !$0.summary.isSeen } : base
    }

    /// The real folders the current selection reads. Nothing else in this type names a folder
    /// to the server, so a synthetic name cannot reach a `SELECT`.
    var targets: [String] { selection.targets(roles: folderRoles) }

    /// 所有信件 earns a chip only when there are at least two folders to merge; with one it
    /// would just be a second name for whichever one resolved.
    var showsAllMailChip: Bool { MailFolderSelection.allMail.targets(roles: folderRoles).count > 1 }

    // MARK: Loading

    /// Paints each covered folder's cached page first, then refreshes the newest page *of each*
    /// from the server, merging the refresh into whatever's already loaded rather than replacing
    /// it (§ pagination): new mail is added, and anything the user already paginated further in
    /// than this first-page refresh covers is kept.
    ///
    /// Exactly one page per real folder: one round trip for an ordinary folder, two for
    /// 所有信件, however far the merged list has already been scrolled. That bound is the whole
    /// reason the merged view refreshes only the newest page per folder — Mail2000 caps
    /// connections and starts answering 「伺服器忙線中」 under load.
    func load() async {
        let selection = self.selection
        guard loadingSelection != selection else { return }
        loadingSelection = selection
        defer { if loadingSelection == selection { loadingSelection = nil } }

        if await paintFromCache() {
            loadState = .loaded
        } else if rows.isEmpty {
            loadState = .loading
        }
        isRefreshing = true
        // Only clear the shared (not per-folder) `isRefreshing`/status-dot state if this call
        // is still the one whose selection is on screen and whose in-flight claim on
        // `loadingSelection` nothing newer has since taken over — otherwise a slow load for a
        // selection the user has since left (or already superseded by a newer load) could stop
        // the spinner or flip the dot red while a still-relevant load is genuinely in flight.
        defer { if selection == self.selection, loadingSelection == selection { isRefreshing = false } }
        do {
            // Resolved before the targets are read, not alongside them: 所有信件 has no name of
            // its own, so which folders it covers is only knowable once `listFolders` has said
            // what the server has.
            if folderRoles.isEmpty {
                let available = try await session.use { client in try await client.listFolders() }
                folderRoles = MailFolderMap.resolve(available: available)
                otherFolders = MailFolderMap.otherFolders(available: available)
                guard selection == self.selection else { return }
                // 所有信件 could not name its folders before this, so the cache paint above had
                // nothing to look up. Now it does.
                if await paintFromCache() { loadState = .loaded }
            }
            guard selection == self.selection else { return }
            let folders = targets
            let fetched = try await session.use { client -> [(String, MailFolderPage)] in
                var result: [(String, MailFolderPage)] = []
                for folder in folders {
                    result.append((folder, try await client.page(folder: folder, olderThanSequence: nil,
                                                                 pageSize: MailConstants.pageSize)))
                }
                return result
            }
            guard selection == self.selection else { return }
            for (folder, fresh) in fetched {
                if let previous = pages[folder], previous.uidValidity != fresh.uidValidity {
                    await dropFolder(folder)
                    pages[folder] = nil
                    guard selection == self.selection else { return }
                }
                var merged = mergeFreshPage(fresh, folder: folder)
                rebuildRows()
                if merged.summaries.isEmpty, merged.messageCount > 0 {
                    merged = await walkBackToVisibleMail(from: merged, folder: folder)
                }
                guard selection == self.selection else { return }
                await save(merged)
            }
            rebuildRows()
            serverStatus = .ok
            loadState = .loaded
        } catch {
            guard selection == self.selection else { return }
            serverStatus = .failed
            loadState = rows.isEmpty ? .failed(MailAccountManager.LoginError(error).message) : .loaded
        }
    }

    /// One cursor per real folder: every folder the selection covers that still has older mail
    /// is paged one page further back and the result re-merged. So the merged list ends only
    /// once *both* folders genuinely have, never merely because the sparser of the two did.
    ///
    /// Known limitation, the same one Android accepted: below the older of the two loaded
    /// horizons the merge is correctly ordered but not yet complete — mail from the folder that
    /// reaches further back is on screen before the other folder's mail of the same age is.
    /// The missing mail arrives with the next load-more, and the list never presents an end
    /// that isn't one, which is the part that would actually mislead.
    func loadMoreIfNeeded(after row: MailListRow) async {
        guard searchResults == nil, !isPaginating, row.id == displayedRows.last?.id else { return }
        let selection = self.selection
        let cursors = targets.compactMap { folder in pages[folder]?.oldestLoadedSequence.map { (folder, $0) } }
        guard !cursors.isEmpty else { return }
        isPaginating = true
        defer { isPaginating = false }
        for (folder, older) in cursors {
            do {
                let next = try await session.use { client in
                    try await client.page(folder: folder, olderThanSequence: older, pageSize: MailConstants.pageSize)
                }
                guard selection == self.selection, var page = pages[folder] else { return }
                let known = Set(page.summaries.map(\.uid))
                page.summaries += next.summaries.filter { !known.contains($0.uid) }
                page.oldestLoadedSequence = next.oldestLoadedSequence
                pages[folder] = page
                rebuildRows()
            } catch MailClientError.folderChanged {
                await recoverFromFolderChange(folder)
                return
            } catch {
                guard selection == self.selection else { return }
                serverStatus = .failed
                return
            }
        }
    }

    func select(_ selection: MailFolderSelection) async {
        guard selection != self.selection else { return }
        self.selection = selection
        pages = [:]
        rows = []
        searchResults = nil
        searchUsedLocalFallback = false
        await load()
    }

    // MARK: Search

    /// Server-side search in each folder the selection covers; where the server refuses (or is
    /// unreachable) only that folder's loaded mail is searched and the list says so (§8.3). A
    /// folder whose search the server did answer still contributes its real results, and the
    /// "loaded mail only" note appears as soon as any one folder fell back.
    func submitSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            clearSearch()
            return
        }
        let selection = self.selection
        var found: [MailListRow] = []
        var usedFallback = false
        var serverFailed = false
        for folder in targets {
            do {
                let matched = try await session.use { client -> [MailSummary] in
                    let matches = try await client.search(folder: folder, query: query)
                    let newest = Array(matches.sorted(by: >).prefix(MailConstants.pageSize))
                    return try await client.summaries(folder: folder, uids: newest)
                }
                guard selection == self.selection else { return }
                found += matched.filter { !$0.isDeleted }.map { MailListRow(folder: folder, summary: $0) }
            } catch {
                guard selection == self.selection else { return }
                if (error as? MailClientError) != .searchUnsupported { serverFailed = true }
                found += (pages[folder]?.summaries ?? [])
                    .filter { Self.matches($0, query) }
                    .map { MailListRow(folder: folder, summary: $0) }
                usedFallback = true
            }
        }
        guard selection == self.selection else { return }
        if serverFailed { serverStatus = .failed }
        searchResults = ordered(found)
        searchUsedLocalFallback = usedFallback
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

    /// Acts on `row`'s own folder, never on `selection`: in 所有信件 the selected chip is not a
    /// folder at all, and the row next to this one may well live somewhere else. The
    /// UIDVALIDITY pinned on the `setFlag` is that folder's own, for the same reason.
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

    /// Called by the message screen after it marks a mail read or unread, and by `toggleRead`
    /// for its own optimistic update and revert.
    ///
    /// `folder` is not decoration: a UID is only unique within its own folder, so a call that
    /// started against one folder must not touch a folder the list is no longer showing.
    /// Without the guard a same-UID row of a *different* message gets flipped here and written
    /// to that folder's cache. In 所有信件 the list shows two folders at once, so the guard is
    /// "is this one of them", and the row it finds is found inside that folder's own page —
    /// never by UID across the merged list, where the same number names two mails.
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

    /// Called by the message screen after it moves or deletes a mail. Scoped to `folder` for the
    /// same reason `markSeenLocally` is — here the stale (or cross-folder) call would remove a
    /// different folder's row outright and decrement that folder's `messageCount`.
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

    /// INBOX-only, as it has always been — 所有信件 included, which refreshes on pull-to-refresh
    /// like every other non-inbox selection. That is also what keeps the merged view entirely
    /// out of the new-mail path: it never reloads off a `.newMail` outcome and so never moves
    /// anything the notification side reads.
    func pollOnce() async {
        let check = runPageCheck
        guard let outcome = try? await session.use({ client in await check(client) }) else { return }
        // `.baselineReset` reloads for the same reason `.newMail` does: INBOX's UIDVALIDITY
        // changed, so every UID on screen belongs to a generation the server has thrown away.
        // Without this the list keeps painting the old generation (and answering taps with
        // `folderChanged`) until something else happens to force a reload.
        switch outcome {
        case .newMail, .baselineReset:
            guard selection == .real(MailConstants.inbox), searchResults == nil else { return }
            await load()
        default:
            return
        }
    }

    // MARK: Internals

    /// Reads a cached page for every folder the selection covers that has none loaded yet, so
    /// the list paints before any of it is asked for again. Returns whether anything landed.
    private func paintFromCache() async -> Bool {
        let cache = self.cache
        var painted = false
        for folder in targets where pages[folder] == nil {
            if let cached = await Self.cachedPage(cache: cache, folder: folder) {
                pages[folder] = cached
                painted = true
            }
        }
        if painted { rebuildRows() }
        return painted
    }

    /// Rebuilds the displayed list from the per-folder pages. A merged view is ordered by date,
    /// because the folders' UID spaces say nothing about each other; a single folder is left
    /// exactly as the server returned it, so nothing about the existing lists changes just
    /// because 所有信件 exists.
    private func rebuildRows() {
        var collected: [MailListRow] = []
        for folder in targets {
            guard let page = pages[folder] else { continue }
            collected += page.summaries.map { MailListRow(folder: folder, summary: $0) }
        }
        rows = selection == .allMail ? collected.sorted(by: Self.newestFirst) : collected
    }

    /// Search results, ordered the way the list they replace is: by date for 所有信件, by UID
    /// for a single folder.
    private func ordered(_ rows: [MailListRow]) -> [MailListRow] {
        selection == .allMail ? rows.sorted(by: Self.newestFirst) : rows.sorted { $0.uid > $1.uid }
    }

    /// The date the row itself shows, then folder and UID — so the order is total and stable
    /// across rebuilds even when two mails share a timestamp, and a mail with no date at all
    /// sinks to the bottom rather than shuffling.
    nonisolated private static func newestFirst(_ lhs: MailListRow, _ rhs: MailListRow) -> Bool {
        let left = lhs.summary.date ?? .distantPast
        let right = rhs.summary.date ?? .distantPast
        if left != right { return left > right }
        if lhs.folder != rhs.folder { return lhs.folder < rhs.folder }
        return lhs.uid > rhs.uid
    }

    /// Merges a freshly fetched first page into whatever's already loaded for that same folder,
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
    ///
    /// All of it is per folder, and always was: 所有信件 merges two of these, it does not
    /// change what any one of them means.
    @discardableResult
    private func mergeFreshPage(_ fresh: MailFolderPage, folder: String) -> MailFolderPage {
        let previous = pages[folder]
        let hadPreviousPage = previous != nil
        let existing = previous?.summaries ?? []
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
            oldestLoadedSequence = previous?.oldestLoadedSequence
        } else if fresh.summaries.isEmpty {
            oldestLoadedSequence = fresh.oldestLoadedSequence
        } else if hadPreviousPage {
            oldestLoadedSequence = previous?.oldestLoadedSequence
        } else {
            oldestLoadedSequence = fresh.oldestLoadedSequence
        }
        let mergedPage = MailFolderPage(
            folder: folder, uidValidity: fresh.uidValidity, messageCount: fresh.messageCount,
            summaries: merged, oldestLoadedSequence: oldestLoadedSequence
        )
        pages[folder] = mergedPage
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
        let selection = self.selection
        while current.summaries.isEmpty, let cursor = current.oldestLoadedSequence,
              fetched < MailConstants.emptyWindowWalkbackPages {
            fetched += 1
            guard let older = try? await session.use({ client in
                try await client.page(folder: folder, olderThanSequence: cursor, pageSize: MailConstants.pageSize)
            }) else { break }
            // A selection change, or the folder being recreated under us: either way this walk
            // has nothing left to say, and the load that follows recovers properly.
            guard selection == self.selection, older.uidValidity == current.uidValidity else { break }
            current = MailFolderPage(
                folder: current.folder, uidValidity: current.uidValidity, messageCount: current.messageCount,
                summaries: older.summaries.sorted { $0.uid > $1.uid },
                oldestLoadedSequence: older.oldestLoadedSequence
            )
            pages[folder] = current
            rebuildRows()
        }
        return current
    }

    /// A folder's UIDVALIDITY no longer matches what a list operation was built from (spec
    /// §8.3): its cached page — and any cached bodies — are meaningless now, so they're
    /// dropped, and the first page is reloaded fresh from the server. Only that folder's: in
    /// 所有信件 the other folder's generation is its own business and is not thrown away.
    ///
    /// Not `private`: the message screen's own move/delete can hit the very same
    /// `MailClientError.folderChanged` on the connection this list view model shares, and
    /// routes its recovery through here too (via `onFolderChanged`) — never through a
    /// `cache.dropFolder` call of its own, which could race and be undone by this type's queued
    /// cache-write chain (`chainCacheWrite`) landing after it (fix round 1, important 2).
    func recoverFromFolderChange(_ folder: String) async {
        await dropFolder(folder)
        guard targets.contains(folder) else { return }
        pages[folder] = nil
        rebuildRows()
        await load()
    }

    /// `markSeenLocally`/`removeLocally` are synchronous (the message screen calls them
    /// without awaiting), so the disk write can't be awaited here — it's queued through
    /// `chainCacheWrite` instead, fire-and-forget.
    private func persist(folder: String) {
        guard let page = pages[folder] else { return }
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

    /// Every cache *write* in this type — `persist(folder:)`'s fire-and-forget save, `load()`'s
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
