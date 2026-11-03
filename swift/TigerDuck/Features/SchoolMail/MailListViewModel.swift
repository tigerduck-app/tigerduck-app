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

    var folders = MailFolderChoice()
    var mailbox = MailboxPages()
    var status = MailListStatus()
    @ObservationIgnored let session: MailPageSession
    @ObservationIgnored let writer: MailListCacheWriter
    @ObservationIgnored let events = MailboxEvents()
    @ObservationIgnored var loads: MailListLoads
    @ObservationIgnored private(set) var search: MailListSearch!
    @ObservationIgnored private(set) var background: MailListBackground!
    @ObservationIgnored private var signOutListener: MailSignOutListener?

    init(
        session: MailPageSession? = nil,
        account: AccountSession? = nil,
        cache: MailCache? = nil,
        noteSeenByPage: ((MailboxStatusInfo, SignIn) async -> Void)? = nil,
        signOutEvents: NotificationCenter = .default,
        warmDelay: @escaping @Sendable () async -> Void = { try? await AppClock.sleep(until: ContinuousClock.now + MailConstants.warmStartDelay) },
        catchUpDelay: @escaping @Sendable () async -> Void = { try? await AppClock.sleep(until: ContinuousClock.now + MailConstants.searchCatchUpInterval) }
    ) {
        // Resolved in the body, not the parameter list: a default-argument expression runs outside
        // the init's MainActor isolation, where `MailPageSession()` and `MailAccountManager.shared`
        // warn in Swift 6 mode and the checker's closure would be isolated to `MailChecker`.
        let account = account ?? MailAccountManager.shared.session
        let session = session ?? MailPageSession(account: account)
        let cache = cache ?? MailAccountManager.shared.cache
        self.session = session
        loads = MailListLoads(account: account)
        writer = MailListCacheWriter(cache: cache)
        // Starts after the warm's delay too, so the refresh that follows a paint goes first.
        let indexer = MailIndexer(session: session, cache: cache, startDelay: warmDelay)
        background = MailListBackground(list: self, indexer: indexer,
                                        noteSeenByPage: noteSeenByPage ?? { await MailChecker.shared.noteSeenByPage($0, for: $1) },
                                        warmDelay: warmDelay)
        search = MailListSearch(list: self, catchUpDelay: catchUpDelay)
        indexer.onFill = { [weak self] folder in self?.search.indexDidFill(folder) }
        events.observe { [weak self] event in self?.apply(event) }
        signOutListener = MailSignOutListener(center: signOutEvents) { [weak self] in self?.resetForAccountChange() }
    }

    var account: AccountSession { loads.account }
    var folderRoles: [MailFolderRole: String] { folders.roles }
    var otherFolders: [String] { folders.others }
    var selection: MailFolderSelection { folders.selection }
    var rows: [MailListRow] { mailbox.rows }
    var loadState: LoadState { status.loadState }
    var serverStatus: ServerStatus { status.serverStatus }
    var syncedAt: Date? { status.syncedAt }
    var isRefreshing: Bool { status.isRefreshing }
    var isPaginating: Bool { status.isPaginating }
    var sentCopyNotice: String? { status.sentCopyNotice }
    var searchResults: [MailListRow]? { search.results }
    var searchUsedLocalFallback: Bool { search.usedLocalFallback }
    var searchText: String {
        get { search.text }
        set { search.text = newValue }
    }
    var unreadOnly: Bool {
        get { folders.unreadOnly }
        set { folders.unreadOnly = newValue }
    }

    func isCurrent(_ selection: MailFolderSelection, _ signIn: SignIn) -> Bool {
        selection == self.selection && signIn.isCurrent
    }

    var displayedRows: [MailListRow] {
        let base = search.results ?? rows
        return unreadOnly ? base.filter { !$0.summary.isSeen } : base
    }

    var targets: [String] { folders.targets }
    var showsAllMailChip: Bool { folders.showsAllMailChip }
    var showsInbox: Bool { targets.contains(MailConstants.inbox) }

    /// The status dot's text, which says OK only once the search index is complete: until then,
    /// and while a pass downloads, it counts the index's mail, or says it is syncing before the
    /// first count. A failed server shows its failure first.
    var statusText: String {
        guard serverStatus == .ok, background.isIndexBusy else { return SyncStatusDot.statusText(serverStatus) }
        return background.indexer.progress?.text() ?? String(localized: "sync_status_syncing")
    }

    /// Whether the status dot spins: a load, or a pass with mail to download.
    var isSyncing: Bool {
        isRefreshing || (serverStatus == .ok && background.indexer.isDownloading)
    }

    func load() async { await MailListLoader.load(list: self) }

    func refresh(forcingIndex: Bool = false) async {
        await background.pausingWarm {
            await load()
            if forcingIndex { background.startIndexIfLoaded(for: .pull) }
        }
    }

    func loadMoreIfNeeded(after row: MailListRow) async {
        guard !isPaginating, row.id == displayedRows.last?.id else { return }
        guard search.results == nil else { return await search.loadMore() }
        await MailListLoader.loadOlder(list: self)
    }

    func select(_ selection: MailFolderSelection) async {
        folders.pickedByUser = true
        guard selection != self.selection else { return }
        folders.selection = selection
        mailbox.removeAll()
        rebuildRows()
        clearSearch()
        await background.pausingWarm {
            await load()
            // The query stays in the field, so the new mailbox shows its results, not its plain list.
            if self.selection == selection, !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await submitSearch()
            }
        }
    }

    func adoptFolderRoles(_ roles: [MailFolderRole: String]) {
        guard roles != folders.roles else { return }
        let before = targets
        folders.roles = roles
        guard targets != before else { return }
        Task { await load() }
    }

    func reportSentCopyNotice(_ message: String) { status.sentCopyNotice = message }
    func dismissSentCopyNotice() { status.sentCopyNotice = nil }
    func submitSearch() async { await search.submit() }
    func clearSearch() { search.clear() }

    func toggleRead(_ row: MailListRow) async {
        await setSeen(!row.summary.isSeen, folder: row.folder, uids: [row.uid])
    }

    func markAllRead(for signIn: SignIn) async {
        for (folder, rows) in Dictionary(grouping: displayedRows.filter { !$0.summary.isSeen }, by: \.folder) where signIn.isCurrent {
            await setSeen(true, folder: folder, uids: rows.map(\.uid), for: signIn)
        }
    }

    private func setSeen(_ seen: Bool, folder: String, uids: [UInt32], for given: SignIn? = nil) async {
        markSeenLocally(folder: folder, uids: uids, seen: seen)
        let validity = mailbox[folder]?.uidValidity
        let signIn = if let given { given } else { await account.startingSignIn }
        do {
            try await session.use(for: signIn) { client in
                try await client.setFlag(.seen, on: seen, folder: folder, uids: uids, expectedUIDValidity: validity)
            }
        } catch where !signIn.isCurrent {
            return
        } catch MailClientError.folderChanged {
            markSeenLocally(folder: folder, uids: uids, seen: !seen)
            await recoverFromFolderChange(folder)
        } catch {
            markSeenLocally(folder: folder, uids: uids, seen: !seen)
        }
    }

    func markSeenLocally(folder: String, uid: UInt32, seen: Bool = true) { markSeenLocally(folder: folder, uids: [uid], seen: seen) }

    private func markSeenLocally(folder: String, uids: [UInt32], seen: Bool) {
        guard targets.contains(folder) else { return }
        for uid in uids {
            mailbox.markSeen(folder: folder, uid: uid, seen: seen)
            search.markSeen(folder: folder, uid: uid, seen: seen)
        }
        rebuildRows()
        if let page = mailbox[folder] { writer.save(page) }
    }

    func removeLocally(folder: String, uid: UInt32) {
        guard targets.contains(folder), mailbox[folder] != nil else { return }
        mailbox.remove(folder: folder, uid: uid)
        search.remove(folder: folder, uid: uid)
        rebuildRows()
        if let page = mailbox[folder] { writer.save(page) }
    }

    private func apply(_ event: MailboxEvents.Event) {
        switch event {
        case let .seen(folder, uid, isSeen): markSeenLocally(folder: folder, uid: uid, seen: isSeen)
        case let .removed(folder, uid): removeLocally(folder: folder, uid: uid)
        case let .folderChanged(folder): Task { await recoverFromFolderChange(folder) }
        case let .folderRoles(roles): adoptFolderRoles(roles)
        case let .sentCopyNotice(notice): reportSentCopyNotice(notice)
        }
    }

    func startPolling(pollFirst: Bool = false) { background.startPolling(pollFirst: pollFirst) }

    func stopPolling() {
        background.stopPolling()
        session.releaseSoon()
    }

    func pollOnce() async { await background.pollOnce() }

    func resetForAccountChange() {
        background.stopPoll()
        resetInMemoryState()
    }

    func waitForWarm() async { await background.waitForWarm() }
    func waitForIndex() async { await background.indexer.waitForPass() }
    func waitForSearchCatchUp() async { await search.catchUp.wait() }
    func waitForCacheWrites() async { await writer.waitForWrites() }

    #if DEBUG
    func resetForServerChange() {
        stopPolling()
        resetInMemoryState()
        Task { await session.close() }
    }
    #endif

    private func resetInMemoryState() {
        loads = MailListLoads(account: account)
        background.reset()
        folders = MailFolderChoice()
        mailbox.removeAll()
        clearSearch()
        searchText = ""
        status = MailListStatus()
    }

    func rebuildRows() {
        mailbox.rebuildRows(of: targets, newestFirst: selection == .allMail)
        status.syncedAt = mailbox.syncedAt(of: targets)
    }

    func ordered(_ rows: [MailListRow]) -> [MailListRow] {
        selection == .allMail ? rows.sorted(by: MailboxPages.newestFirst) : rows.sorted { $0.uid > $1.uid }
    }

    func setPage(_ page: MailFolderPage, folder: String) {
        mailbox[folder] = page
        rebuildRows()
    }

    func recoverFromFolderChange(_ folder: String) async {
        await writer.dropFolder(folder)
        guard targets.contains(folder) else { return }
        mailbox.drop(folder)
        rebuildRows()
        await load()
    }
}
#endif
