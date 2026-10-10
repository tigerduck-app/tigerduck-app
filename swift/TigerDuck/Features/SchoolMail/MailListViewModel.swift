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
    /// Inbox only until `LIST` has answered — see `adoptDefaultSelection`, which turns this into
    /// All mail the moment there is something to merge. It cannot start as `.allMail`: that
    /// selection resolves to the folders the server reported, and before `LIST` it resolves to
    /// nothing at all.
    private(set) var selection: MailFolderSelection = .real(MailConstants.inbox)
    /// The merged list, newest first. Every entry carries the real folder it came from — see
    /// `MailListRow` — and every action a row leads to addresses *that* folder, never
    /// `selection`, which for All mail is not a folder at all.
    private(set) var rows: [MailListRow] = []
    private(set) var loadState: LoadState = .idle
    private(set) var serverStatus: ServerStatus = .unknown
    private(set) var isRefreshing = false
    private(set) var isPaginating = false
    private(set) var searchResults: [MailListRow]?
    private(set) var searchUsedLocalFallback = false
    /// What became of the last sent copy, when it is something the user should know — see
    /// `reportSentCopyNotice`.
    private(set) var sentCopyNotice: String?
    var searchText = ""
    var unreadOnly = false

    @ObservationIgnored let session: MailPageSession
    @ObservationIgnored private let cache: MailCache
    @ObservationIgnored private let runPageCheck: (any MailClient) async -> MailCheckOutcome
    /// One page per *real* folder, keyed by folder name. All mail holds two of them and merges
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
    /// Whether something has actually *chosen* a folder — a chip tap, or a mail notification
    /// naming the folder it arrived in (both go through `select`). All mail is only the default,
    /// so once a choice has been made it must never be overwritten by one, however late the
    /// server's folder list turns up.
    @ObservationIgnored private var selectionWasChosen = false
    /// The tail of the cache-write chain — see `chainCacheWrite`.
    @ObservationIgnored private var pendingCacheWrite: Task<Void, Never>?
    /// Bumped by every sign-out (`resetForAccountChange`). Work that started under an earlier
    /// value is the previous student's, and is dropped exactly like work for a selection the
    /// user has left — `isCurrent`. The selection alone cannot tell: the reset puts it back on
    /// Inbox, which is very likely what the stale load was fetching.
    @ObservationIgnored private var accountEpoch = 0
    /// The server matches the last search has not fetched yet, per folder: the UIDs, newest first,
    /// and the generation `search` found them under — what scrolling to the end of the results
    /// fetches next (`loadMoreSearchResults`).
    @ObservationIgnored private var unfetchedMatches: [String: (uidValidity: UInt32, uids: [UInt32])] = [:]
    /// Bumped by every search submitted or cleared, so a results page still on the wire for an
    /// earlier query is dropped rather than appended to the results of this one.
    @ObservationIgnored private var searchGeneration = 0
    /// The background warm of the folders the list is not showing — see `startWarm`.
    @ObservationIgnored private var warmTask: Task<Void, Never>?
    /// True once a warm queue has run to its end, so coming back to the screen knows there is
    /// nothing left to warm rather than going to the server to find that out.
    @ObservationIgnored private var warmDone = false
    /// Set while the screen is away (`stopPolling`), so a refresh that lands after the user left
    /// does not start warming for a screen nobody is looking at.
    @ObservationIgnored private var isPaused = false
    @ObservationIgnored private let warmDelay: @Sendable () async -> Void
    @ObservationIgnored nonisolated(unsafe) private var signOutObserver: (any NSObjectProtocol)?
    @ObservationIgnored private let signOutEvents: NotificationCenter

    init(
        session: MailPageSession? = nil,
        cache: MailCache? = nil,
        runPageCheck: @escaping (any MailClient) async -> MailCheckOutcome = { await MailChecker.shared.check(trigger: .page, using: $0) },
        signOutEvents: NotificationCenter = .default,
        warmDelay: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: MailConstants.warmStartDelay) }
    ) {
        // Both defaults are resolved in the body, not the parameter list: a default-argument
        // expression runs outside the init's MainActor isolation, so `MailPageSession()` and
        // `MailAccountManager.shared`, both MainActor-isolated, would warn there in Swift 6 mode.
        self.session = session ?? MailPageSession()
        self.cache = cache ?? MailAccountManager.shared.cache
        self.runPageCheck = runPageCheck
        self.signOutEvents = signOutEvents
        self.warmDelay = warmDelay
        // The view model survives a sign-out (`@State` on `SchoolMailView`). Without this reset the
        // next student first sees the previous student's list, and an in-flight load writes the
        // previous student's pages into a cache that stamps them with whoever is signed in then.
        signOutObserver = signOutEvents.addObserver(forName: MailAccountManager.didSignOut, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.resetForAccountChange() }
        }
    }

    deinit {
        if let signOutObserver { signOutEvents.removeObserver(signOutObserver) }
    }

    /// Whether work that started for `selection` under `epoch` still belongs on screen.
    private func isCurrent(_ selection: MailFolderSelection, _ epoch: Int) -> Bool {
        selection == self.selection && epoch == accountEpoch
    }

    var displayedRows: [MailListRow] {
        let base = searchResults ?? rows
        return unreadOnly ? base.filter { !$0.summary.isSeen } : base
    }

    /// The real folders the current selection reads. Nothing else in this type names a folder
    /// to the server, so a synthetic name cannot reach a `SELECT`.
    var targets: [String] { selection.targets(roles: folderRoles) }

    /// All mail earns a chip only when there are at least two folders to merge; with one it
    /// would just be a second name for whichever one resolved.
    var showsAllMailChip: Bool { MailFolderSelection.allMail.targets(roles: folderRoles).count > 1 }

    /// Whether Inbox is one of the folders currently on screen — true for the Inbox chip and
    /// for All mail, which merges the inbox in. Anything that used to ask
    /// `selection == .real(inbox)` means *this*: All mail is now the screen the list opens on,
    /// and a test written as "is the inbox selected" silently stops firing there.
    var showsInbox: Bool { targets.contains(MailConstants.inbox) }

    // MARK: Loading

    /// Paints each covered folder's cached page first, then refreshes the newest page of each
    /// from the server. The refresh is merged into what is already loaded, not swapped in: new
    /// mail is added, and mail the user paginated to beyond this first page is kept.
    ///
    /// One page per real folder: one round trip for an ordinary folder, two for All mail,
    /// however far the merged list has been scrolled. That bound is why the merged view refreshes
    /// only the newest page per folder: Mail2000 caps connections and starts answering
    /// "The mail server is busy" under load.
    func load() async {
        // `var`, not `let`: the opening load may adopt All mail once `LIST` names the folders
        // (`adoptDefaultSelection`). The checks below compare it to `self.selection`, so it must
        // follow the adoption or the load abandons itself as stale. Both `defer`s read it at exit.
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
        // The `isRefreshing`/status-dot state is shared, not per folder, so only a load whose
        // selection is on screen and that still holds `loadingSelection` clears it. Otherwise a
        // stale load could stop the spinner or flip the dot red while a current one is in flight.
        defer { if isCurrent(selection, epoch), loadingSelection == selection { isRefreshing = false } }
        do {
            // Resolved before the targets are read, not alongside them: All mail has no name of
            // its own, so which folders it covers is only knowable once `listFolders` has said
            // what the server has.
            if folderRoles.isEmpty {
                let available = try await session.use { client in try await client.listFolders() }
                // The previous student's folders are not the next one's.
                guard epoch == accountEpoch else { return }
                folderRoles = MailFolderMap.resolve(available: available)
                otherFolders = MailFolderMap.otherFolders(available: available)
                guard isCurrent(selection, epoch) else { return }
                // All mail first resolves here, so this is where the default can apply. Not via
                // `select`, which would start a second load and throw this one away: the `page`
                // calls below already fetch the folders the new selection covers.
                if adoptDefaultSelection() {
                    selection = self.selection
                    loadingSelection = selection
                }
                // All mail could not name its folders before this, so the cache paint above had
                // nothing to look up. Now it does.
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
            for (folder, fresh) in fetched {
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

    /// A load the user asked for (the screen opening, a pull, Retry, the compose sheet closing),
    /// with the warm stopped first and started again once the list is up.
    ///
    /// The warm shares the one connection and `AsyncSerialLock` is FIFO, so a running warm would
    /// queue this load behind every folder still waiting. A page in flight cannot be aborted
    /// (SwiftMail commands run to completion), so this waits at most one page, and the warm's
    /// start delay makes even that unlikely. Without the restart the first pull would end warming
    /// for the visit. The 60 s poll calls `load()` alone: re-warming each minute is not its job.
    func refresh() async {
        cancelWarm()
        await load()
        startWarmIfLoaded()
    }

    /// One cursor per real folder: every covered folder that still has older mail is paged one
    /// page further back and the result re-merged. So the merged list ends only once both
    /// folders have, never because the sparser of the two did.
    ///
    /// Known limitation, shared with the Android app: below the older of the two loaded horizons
    /// the merge is ordered but incomplete, since mail from the folder reaching further back
    /// shows before the other folder's mail of the same age. That mail arrives with the next
    /// load-more, and the list never shows an end that is not one, which is what would mislead.
    func loadMoreIfNeeded(after row: MailListRow) async {
        guard !isPaginating, row.id == displayedRows.last?.id else { return }
        guard searchResults == nil else { return await loadMoreSearchResults() }
        let selection = self.selection
        let epoch = accountEpoch
        let cursors = targets.compactMap { folder in pages[folder]?.oldestLoadedSequence.map { (folder, $0) } }
        guard !cursors.isEmpty else { return }
        isPaginating = true
        defer { isPaginating = false }
        for (folder, older) in cursors {
            do {
                let next = try await session.use { client in
                    try await client.page(folder: folder, olderThanSequence: older, pageSize: MailConstants.pageSize)
                }
                guard isCurrent(selection, epoch), var page = pages[folder] else { return }
                // The merge dedupes by UID, which holds only within one UIDVALIDITY: across a
                // recreated folder it would keep stale rows and drop new mail reusing their UIDs.
                // `page()` cannot detect this, so recover like the `folderChanged` arm below.
                guard next.uidValidity == page.uidValidity else {
                    await recoverFromFolderChange(folder)
                    return
                }
                let known = Set(page.summaries.map(\.uid))
                page.summaries += next.summaries.filter { !known.contains($0.uid) }
                page.oldestLoadedSequence = next.oldestLoadedSequence
                pages[folder] = page
                rebuildRows()
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

    func select(_ selection: MailFolderSelection) async {
        // Before the early-out, not after: a notification that names Inbox while Inbox is still
        // the pre-`LIST` placeholder has chosen it just as deliberately as a chip tap would
        // have, and the default must not come along afterwards and move the list off it.
        selectionWasChosen = true
        guard selection != self.selection else { return }
        self.selection = selection
        pages = [:]
        rows = []
        searchResults = nil
        searchUsedLocalFallback = false
        cancelWarm()
        await load()
        // Rebuilt, not resumed: the folders worth warming are the ones the *new* selection is
        // not showing, which now includes the one the user just left.
        startWarmIfLoaded()
    }

    /// Adopts the role map that a screen this list presented re-resolved after creating a
    /// missing role folder (`MailFolderProvisioner`). `load()` lists folders only while
    /// `folderRoles` is empty, so without this the first map stands all session: the new folder
    /// gets no chip, the next message opened tries to create Trash again, and, for Sent, All mail
    /// keeps merging one folder instead of two. The map is never patched in place: what arrives
    /// came from a fresh `listFolders()` through `MailFolderMap.resolve`, like this type's own.
    ///
    /// Reloads when the new map changes what the selection covers (All mail gaining Sent).
    func adoptFolderRoles(_ roles: [MailFolderRole: String]) {
        guard roles != folderRoles else { return }
        let before = targets
        folderRoles = roles
        guard targets != before else { return }
        Task { await load() }
    }

    /// A mail composed from this screen went out, but its copy did not reach Sent — the send
    /// succeeded, so this is a notice the user dismisses, never a `loadState` failure.
    ///
    /// Nothing clears it but `dismissSentCopyNotice()`. In particular `load()` must not: the
    /// compose sheet's own dismissal triggers a reload, so a notice cleared by loading would be
    /// wiped by the very act of the sheet closing and never be seen at all.
    func reportSentCopyNotice(_ message: String) {
        sentCopyNotice = message
    }

    func dismissSentCopyNotice() {
        sentCopyNotice = nil
    }

    // MARK: Search

    /// Server-side search in each folder the selection covers. Where the server refuses or is
    /// unreachable, only that folder's loaded mail is searched and the list says so. A folder
    /// the server did answer still contributes its real results, and the "loaded mail only"
    /// note appears as soon as any one folder fell back.
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
                // Recreated between the search and its first page. The matched UIDs name other
                // mail now, and so does the cached page a fallback would search, so neither is
                // listed: the folder recovers instead, as it does on a later page.
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
        // Nothing on screen means no last row to ask for more, however many matches are left.
        if displayedRows.isEmpty { await loadMoreSearchResults() }
    }

    /// The next page of each folder's unfetched matches, pinned to the generation they were found
    /// under. A page can add nothing that shows — every match `\Deleted`, or read under Unread
    /// only — and then no new last row appears to ask for the next one, so this keeps going until
    /// the end of the list moves or the matches run out. The same known limitation as the list's
    /// own load-more applies to All mail: the merge is ordered but not yet complete below the
    /// older of the folders' loaded horizons.
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
                    // Recreated since the search: its UIDs name other mail now, the ones already
                    // listed included. They go, and the folder recovers like any other change.
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

    // MARK: Changes

    /// Acts on `row`'s own folder, never on `selection`: in All mail the selected chip is not a
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
    /// A UID is unique only within its folder, so a call that started against one folder must
    /// not touch a folder the list has since left, or a different message with the same UID is
    /// flipped and written to that folder's cache. In All mail the guard accepts either shown
    /// folder, and the row is found in that folder's own page, never by UID across the merged
    /// list, where one number can name two mails.
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
        isPaused = false
        // Leaving cancels the warm, and a visit that left inside its start delay — following a
        // notification and coming straight back — would otherwise leave every other folder cold
        // for the rest of it.
        if !warmDone, warmTask == nil { startWarmIfLoaded() }
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
        isPaused = true
        pollTask?.cancel()
        pollTask = nil
        cancelWarm()
        session.releaseSoon()
    }

    /// Throws away everything in memory that belonged to the student who just signed out: the
    /// resolved folder roles, the loaded pages and the rows built from them. Left alone, they
    /// would be the next student's first frame, with row taps and swipe actions addressing the
    /// previous student's folders and UIDs. The held connection is `MailPageSession`'s to close,
    /// on the same event.
    func resetForAccountChange() {
        pollTask?.cancel()
        pollTask = nil
        resetInMemoryState()
    }

    /// Test hook: returns once the current warm, if any, has finished or stopped.
    func waitForWarm() async {
        await warmTask?.value
    }

    /// Test hook: returns once every cache write queued so far has landed.
    func waitForCacheWrites() async {
        await pendingCacheWrite?.value
    }

    #if DEBUG
    /// Throws away everything resolved against the previous mail server after the DEBUG
    /// developer override changed it.
    ///
    /// `DevMailServerSettings` handles the on-disk caches and the account; it signs out, which
    /// reaches `resetForAccountChange` too. This is the same in-memory reset, callable directly
    /// for the override's own flow. The held IMAP connection goes as well: it is authenticated
    /// against the old server, and `MailPageSession.close()` logs it out rather than letting it
    /// idle there for 30 s.
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
        isRefreshing = false
        isPaginating = false
        sentCopyNotice = nil
    }

    /// Reloads when the inbox is on screen, which includes All mail: it merges the inbox in and
    /// is the screen the list opens on. A `selection == .real(inbox)` check would never fire
    /// there, and new mail would not appear without a pull-to-refresh.
    ///
    /// The check itself (`runPageCheck`) is inbox-only and is the only thing here that touches
    /// the notification baseline; `load()` only reads pages. So a merged reload costs one extra
    /// `page` round trip (Sent's) per poll that finds new mail, not per poll, and moves nothing
    /// the notification side reads.
    func pollOnce() async {
        let check = runPageCheck
        guard let outcome = try? await session.use({ client in await check(client) }) else { return }
        // `.baselineReset` reloads like `.newMail`: INBOX's UIDVALIDITY changed, so every UID on
        // screen is from a generation the server discarded. Without the reload the list keeps
        // painting it, and answering taps with `folderChanged`, until something forces a reload.
        switch outcome {
        case .newMail:
            guard showsInbox, searchResults == nil else { return }
            // Read before the reload, from the inbox's own page: in All mail the rows also hold
            // Sent's, whose UIDs say nothing about the inbox's.
            let previousNewest = pages[MailConstants.inbox]?.summaries.map(\.uid).max() ?? 0
            await load()
            await prefetchArrivedBodies(after: previousNewest)
        case .baselineReset:
            guard showsInbox, searchResults == nil else { return }
            await load()
        default:
            return
        }
    }

    /// The new-mail body prefetch `MailChecker` does for a notification, on the page poll's path.
    /// The poll skips the checker's prefetch (the page trigger only answers "is there new mail"),
    /// yet a mail arriving while this list is open is the likeliest to be tapped within seconds.
    /// Arrivals are the inbox rows above `previousNewest`, the highest UID held before this
    /// poll's reload. At most `MailConstants.bodyPrefetchLimit`, newest first, one `use(_:)` per
    /// body so a tap waits behind at most one. Silent: it touches neither `loadState` nor
    /// `serverStatus`, and a body that fails only leaves that mail slow to open. `detail` fetches
    /// with `BODY.PEEK`, so nothing is marked read.
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
                    try await client.detail(folder: inbox, uid: uid, expectedUIDValidity: validity)
                }
                guard epoch == accountEpoch else { return }
                chainCacheWrite { cache.saveDetail(detail, folder: inbox, uidValidity: validity) }
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
                    let page = try await self.session.use { client in
                        try await client.page(folder: folder, olderThanSequence: nil, pageSize: MailConstants.warmPageSize)
                    }
                    guard !Task.isCancelled, self.accountEpoch == epoch else { return }
                    // The screen owns a folder it has moved onto since, and its page in memory
                    // and the one on disk must not diverge.
                    if self.targets.contains(folder) { continue }
                    await self.chainCacheWrite {
                        if Self.warmShouldWrite(page, over: cache.loadPage(folder: folder)) { cache.savePage(page) }
                    }.value
                } catch let error as MailClientError where MailChecker.endsPrefetch(error) {
                    return
                } catch {
                    continue
                }
            }
            // Reached only by running the queue out; a cancelled warm leaves this false, which is
            // what tells the next `startPolling` there is still warming to do.
            guard let self, !Task.isCancelled else { return }
            self.warmDone = true
            self.warmTask = nil
        }
    }

    /// Only after a load that reached the server: after a failed one the list still reads
    /// `.loaded` (cached rows stay up), and warming then would only reconnect and log in again
    /// against a server that has just refused.
    private func startWarmIfLoaded() {
        guard !isPaused, loadState == .loaded, serverStatus == .ok else { return }
        startWarm()
    }

    private func cancelWarm() {
        warmTask?.cancel()
        warmTask = nil
    }

    /// Whether a warm's page may replace what is cached for its folder: always over nothing and
    /// over another UIDVALIDITY generation, otherwise only when it is at least as long. A warm
    /// fetches a short first page, and a cache the user paged fifty rows further into is worth
    /// more than it.
    nonisolated static func warmShouldWrite(_ page: MailFolderPage, over cached: MailFolderPage?) -> Bool {
        guard let cached, cached.uidValidity == page.uidValidity else { return true }
        return page.summaries.count >= cached.summaries.count
    }

    // MARK: Internals

    /// Moves the list onto All mail the first time the server's folder list allows it, and
    /// reports whether it did. The selection cannot start there: All mail has no name of its own
    /// and resolves to the folders `LIST` reported, so before that it reads no folders and has
    /// no chip to leave it by. Without All mail (a server missing Sent, say) the list stays on
    /// Inbox; once something has chosen a folder (`selectionWasChosen`), it stays there.
    ///
    /// Not a `select` call: `select` clears the pages and reloads, but the pages hold the inbox's
    /// fresh cache paint, the reload is already in flight, and All mail reads the same pages.
    private func adoptDefaultSelection() -> Bool {
        guard !selectionWasChosen, selection != .allMail, showsAllMailChip else { return false }
        selection = .allMail
        return true
    }

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
    /// because All mail exists.
    private func rebuildRows() {
        var collected: [MailListRow] = []
        for folder in targets {
            guard let page = pages[folder] else { continue }
            collected += page.summaries.map { MailListRow(folder: folder, summary: $0) }
        }
        rows = selection == .allMail ? collected.sorted(by: Self.newestFirst) : collected
    }

    /// Search results, ordered the way the list they replace is: by date for All mail, by UID
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

    /// Merges a fresh first page into the folder's loaded page, so a refresh never drops mail the
    /// user paginated to. Every UID in `fresh` wins. An existing row survives only below the fresh
    /// window's floor; one inside it that `fresh` lacks was expunged, moved or flagged `\Deleted`
    /// elsewhere and goes. An empty `fresh` keeps every row unless `messageCount == 0`: `page()`
    /// hides `\Deleted` rows, a read can transiently come back empty, and blanking would overwrite
    /// the cache with no row to paginate from. A later window that reaches the stale ones corrects
    /// them. The cursor stays the existing page's, as new mail only appends sequence numbers; an
    /// empty `fresh` with no rows kept takes its own. Per folder: All mail merges two of these.
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
        let epoch = accountEpoch
        while current.summaries.isEmpty, let cursor = current.oldestLoadedSequence,
              fetched < MailConstants.emptyWindowWalkbackPages {
            fetched += 1
            guard let older = try? await session.use({ client in
                try await client.page(folder: folder, olderThanSequence: cursor, pageSize: MailConstants.pageSize)
            }) else { break }
            // A selection change, or the folder being recreated under us: either way this walk
            // has nothing left to say, and the load that follows recovers properly.
            guard isCurrent(selection, epoch), older.uidValidity == current.uidValidity else { break }
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

    /// A folder's UIDVALIDITY differs from the one a list operation was built from, so its
    /// cached page and bodies are dropped and its first page is reloaded from the server. Only
    /// that folder: in All mail the other folder's generation is its own and is kept.
    ///
    /// Not `private`: the message screen's move or delete can hit the same `folderChanged` on
    /// the connection this view model shares, and recovers through here (`onFolderChanged`).
    /// A `cache.dropFolder` of its own could race this type's queued `chainCacheWrite` and be
    /// undone by a write that lands after it.
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
