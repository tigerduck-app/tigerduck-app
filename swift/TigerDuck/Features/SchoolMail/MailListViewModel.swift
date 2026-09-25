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
        // Both defaults are resolved here, in the init's own MainActor-isolated body, rather
        // than in the default-parameter expressions above: a default-parameter expression is
        // evaluated outside the initializer's own isolation, so `MailPageSession()` (a
        // MainActor-isolated init) and `MailAccountManager.shared` (a MainActor-isolated
        // static property) can't be reached from there without a warning under Swift 6 mode.
        self.session = session ?? MailPageSession()
        self.cache = cache ?? MailAccountManager.shared.cache
        self.runPageCheck = runPageCheck
        self.signOutEvents = signOutEvents
        self.warmDelay = warmDelay
        // The screen keeps this view model across a sign-out (it is `@State` on `SchoolMailView`),
        // so without this the next student's first frame is the previous student's list, and a
        // load that was in flight writes the previous student's pages into a cache that stamps
        // them with whoever is signed in by then.
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

    /// Paints each covered folder's cached page first, then refreshes the newest page *of each*
    /// from the server, merging the refresh into whatever's already loaded rather than replacing
    /// it (§ pagination): new mail is added, and anything the user already paginated further in
    /// than this first-page refresh covers is kept.
    ///
    /// Exactly one page per real folder: one round trip for an ordinary folder, two for
    /// All mail, however far the merged list has already been scrolled. That bound is the whole
    /// reason the merged view refreshes only the newest page per folder — Mail2000 caps
    /// connections and starts answering "The mail server is busy" under load.
    func load() async {
        // `var`, not `let`: the opening load may adopt All mail partway through, once `LIST` has
        // said the folders exist (`adoptDefaultSelection`). Every `selection == self.selection`
        // check below asks "is what I am fetching still what the screen wants", so this has to
        // follow the adoption or the load would abandon itself as stale. The two `defer`s read
        // it at scope exit, so they follow it too.
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
        // Only clear the shared (not per-folder) `isRefreshing`/status-dot state if this call
        // is still the one whose selection is on screen and whose in-flight claim on
        // `loadingSelection` nothing newer has since taken over — otherwise a slow load for a
        // selection the user has since left (or already superseded by a newer load) could stop
        // the spinner or flip the dot red while a still-relevant load is genuinely in flight.
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
                // The first moment All mail is resolvable, and so the first moment the default
                // can be applied. Doing it here rather than through `select` keeps the opening
                // load to a single pass: the folders it now covers are fetched by the `page`
                // calls just below, with no second load and no first one thrown away.
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

    /// A load the user asked for — the screen opening, a pull, Retry, the compose sheet closing —
    /// with the warm stopped first and started again once the list is up.
    ///
    /// Stopped first because the warm shares the one connection, and `AsyncSerialLock` is FIFO:
    /// left running, this load would queue behind every folder still waiting its turn. It cannot
    /// abort a page already in flight — SwiftMail's commands run to completion — so the most this
    /// waits is one page, and the warm's start delay makes even that unlikely. Restarted rather
    /// than only stopped, or the first pull would end warming for the rest of the visit.
    ///
    /// Not what the 60 s poll calls: a poll that finds new mail reloads through `load()` alone,
    /// and warming every other folder again once a minute is not what it is for.
    func refresh() async {
        cancelWarm()
        await load()
        startWarmIfLoaded()
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
                // The merge below dedupes by UID, and a UID only means anything within one
                // UIDVALIDITY generation. If the folder was recreated between the page already
                // held and this one, the server is reusing those numbers for entirely different
                // messages: the stale rows would stay (pointing at mail that no longer exists,
                // and answering taps with `folderChanged`) and every genuinely new message whose
                // UID was reused would be discarded here as a duplicate. Recover the folder
                // instead — the same recovery the `folderChanged` arm just below runs, which is
                // what `page()` itself would have thrown had it been able to compare generations.
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

    /// Adopts a role map a screen this list presented re-resolved after creating a missing role
    /// folder on demand (`MailFolderProvisioner`).
    ///
    /// `load()` only lists folders while `folderRoles` is empty, so without this the map resolved
    /// at the first load would stand for the whole session: the new folder would have no chip, a
    /// second message opened would believe Trash still does not exist and try to create it again,
    /// and — for Sent — "All mail" would go on merging one folder instead of two. The map is
    /// never patched in place here; what arrives already came from a fresh `listFolders()` run
    /// through `MailFolderMap.resolve`, which is the same source this type's own resolution uses.
    ///
    /// Adopting a wider set of folders can change what the current selection covers, so it
    /// reloads when it does — "All mail" gaining Sent has to go and fetch it.
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
        let epoch = accountEpoch
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
                guard isCurrent(selection, epoch) else { return }
                found += matched.filter { !$0.isDeleted }.map { MailListRow(folder: folder, summary: $0) }
            } catch {
                guard isCurrent(selection, epoch) else { return }
                if (error as? MailClientError) != .searchUnsupported { serverFailed = true }
                found += (pages[folder]?.summaries ?? [])
                    .filter { Self.matches($0, query) }
                    .map { MailListRow(folder: folder, summary: $0) }
                usedFallback = true
            }
        }
        guard isCurrent(selection, epoch) else { return }
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
    /// `folder` is not decoration: a UID is only unique within its own folder, so a call that
    /// started against one folder must not touch a folder the list is no longer showing.
    /// Without the guard a same-UID row of a *different* message gets flipped here and written
    /// to that folder's cache. In All mail the list shows two folders at once, so the guard is
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
    /// Throws away everything that was resolved against the previous mail server, after the
    /// DEBUG developer override changed it.
    ///
    /// The on-disk caches and the account are dealt with by `DevMailServerSettings`, which
    /// signs out (and so reaches `resetForAccountChange` too); this is the same in-memory reset,
    /// kept callable directly for the override's own flow.
    ///
    /// The held IMAP connection goes too: it is authenticated against the old server, and
    /// `MailPageSession.close()` logs it out rather than letting it idle there for 30 s.
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

    /// Reloads when the inbox is on screen — which now means All mail as well as Inbox itself,
    /// because All mail merges the inbox in and is the screen the list opens on. Written as
    /// `selection == .real(inbox)` it would simply stop firing on that screen, and new mail
    /// would never appear without a pull-to-refresh.
    ///
    /// The check itself (`runPageCheck`) is inbox-only and unchanged, and it is the only thing
    /// here that touches the notification baseline — `load()` only reads pages. So a merged
    /// reload costs one extra `page` round trip (Sent's) per *new-mail* poll, never per
    /// poll, and moves nothing the notification side reads.
    func pollOnce() async {
        let check = runPageCheck
        guard let outcome = try? await session.use({ client in await check(client) }) else { return }
        // `.baselineReset` reloads for the same reason `.newMail` does: INBOX's UIDVALIDITY
        // changed, so every UID on screen belongs to a generation the server has thrown away.
        // Without this the list keeps painting the old generation (and answering taps with
        // `folderChanged`) until something else happens to force a reload.
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
    ///
    /// The poll never goes through the checker's own prefetch — the page trigger only answers
    /// "is there new mail" — so in the one case where a mail is almost certain to be tapped
    /// within seconds, the app open on this very list, the row appeared and opening it still
    /// spun. The arrivals are exactly the inbox rows above `previousNewest`, the highest UID the
    /// list held before this poll's reload, never the page the user has been reading all along.
    ///
    /// Bounded to `MailConstants.bodyPrefetchLimit`, newest first, one `use(_:)` per body so a
    /// tap waits behind at most one of them. Silent: it touches neither `loadState` nor
    /// `serverStatus`, and a body that will not come down only means that opening that mail is
    /// as slow as it used to be. `detail` fetches with `BODY.PEEK`, so nothing is marked read.
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

    /// Warms the folders the user is *not* looking at, so a chip tap paints from cache instead of
    /// a spinner.
    ///
    /// The role folders in chip order, minus whatever the selection already shows. One at a time
    /// and on the page's own connection — Mail2000 caps connections and answers "server busy"
    /// under load, so a fan-out would be paid for by the screen the user is actually reading —
    /// and `MailConstants.warmPageSize` rows each, enough to fill a screen.
    ///
    /// Silent by construction: it never touches `loadState`, `serverStatus`, `rows` or `pages`.
    /// It writes only the cache, and never shortens a folder cache the user has already paged
    /// further into (`warmShouldWrite`). A failure means only that a later chip tap is as slow as
    /// it used to be, so it is swallowed — except one that says the connection itself is gone,
    /// which stops the queue rather than reopening and logging in again once per folder (NTUST
    /// counts failed logins towards a lockout).
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

    /// Moves the list onto All mail the first time the server's folder list makes that possible,
    /// and reports whether it did. This is what "the list opens on All mail" actually means: the
    /// selection cannot simply *start* there, because All mail has no name of its own and
    /// resolves to the folders `LIST` reported — before that it resolves to nothing, and the
    /// list would open on a selection reading no folders at all, with no chip yet drawn to
    /// leave it by.
    ///
    /// Nothing happens when All mail is not there to be selected (a server missing Sent, say):
    /// the list stays on Inbox, which is both the placeholder it started on and the right answer.
    /// Nothing happens either once something has genuinely chosen a folder — see
    /// `selectionWasChosen`.
    ///
    /// Not a `select` call: `select` clears the pages and reloads, and here the pages are the
    /// inbox's freshly painted cache and the reload is the one already in flight. The merged
    /// view is composed from the same per-folder pages, so the inbox's simply stays.
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
    /// All of it is per folder, and always was: All mail merges two of these, it does not
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

    /// A folder's UIDVALIDITY no longer matches what a list operation was built from (spec
    /// §8.3): its cached page — and any cached bodies — are meaningless now, so they're
    /// dropped, and the first page is reloaded fresh from the server. Only that folder's: in
    /// All mail the other folder's generation is its own business and is not thrown away.
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
