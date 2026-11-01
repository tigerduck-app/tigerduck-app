#if os(iOS)
import Foundation

/// The list's work while the page is on screen: the minute poll of the inbox, warming the other
/// folders' caches, and the search index's passes. A closed page pauses all three.
@MainActor
final class MailListBackground {
    let indexer: MailIndexer
    private(set) var isPaused = false
    private var pollTask: Task<Void, Never>?
    private let noteSeenByPage: (MailboxStatusInfo) async -> Void
    private var warmTask: Task<Void, Never>?
    private var warmDone = false
    private let warmDelay: @Sendable () async -> Void
    /// Weak: the poll and warm tasks outlive the list once the page closes or the account signs out.
    private weak var list: MailListViewModel?

    init(
        list: MailListViewModel, indexer: MailIndexer, noteSeenByPage: @escaping (MailboxStatusInfo) async -> Void,
        warmDelay: @escaping @Sendable () async -> Void
    ) {
        self.list = list
        self.indexer = indexer
        self.noteSeenByPage = noteSeenByPage
        self.warmDelay = warmDelay
    }

    func startPolling(pollFirst: Bool) {
        guard let list else { return }
        isPaused = false
        list.search.resumeCatchUp()
        if !warmDone, warmTask == nil { startWarmIfLoaded() }
        startIndexIfLoaded()
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            if pollFirst { await self?.pollOnce() }
            while !Task.isCancelled {
                try? await AppClock.sleep(until: ContinuousClock.now + .seconds(MailConstants.pagePollInterval))
                guard !Task.isCancelled, let self else { return }
                await self.pollOnce()
                self.startIndexIfLoaded()
            }
        }
    }

    func stopPolling() {
        isPaused = true
        stopPoll()
        cancelWarm()
        indexer.stop()
        list?.search.catchUp.pause()
    }

    func stopPoll() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Forgets the warm and the index of the account or server that changed.
    func reset() {
        cancelWarm()
        indexer.reset()
        warmDone = false
    }

    func waitForWarm() async { await warmTask?.value }

    /// A pass with mail to download.
    var isDownloading: Bool { indexer.isRunning && indexer.progress?.total != 0 }

    /// An index that is already current shows nothing rather than spinning at 0/0.
    var isIndexBusy: Bool { !indexer.isComplete || isDownloading }

    func pollOnce() async {
        guard let list else { return }
        guard list.showsInbox, !list.search.isShowingResults else { return }
        let selection = list.selection
        let epoch = list.loads.accountEpoch
        let inbox = MailConstants.inbox
        let folders = list.targets
        guard let statuses = try? await list.session.use({ client -> [String: MailboxStatusInfo] in
                  var result = [inbox: try await client.status(folder: inbox)]
                  for folder in folders where folder != inbox {
                      result[folder] = try? await client.status(folder: folder)
                  }
                  return result
              }),
              let status = statuses[inbox], list.isCurrent(selection, epoch), !list.search.isShowingResults else { return }
        let checkedAt = Date()
        let before = list.mailbox[inbox]
        if statuses.contains(where: { Self.hasUnshownMail($0.value, page: list.mailbox[$0.key]) }) {
            await list.load()
            guard list.isCurrent(selection, epoch) else { return }
            if let before, before.uidValidity == status.uidValidity {
                await prefetchArrivedBodies(after: before.summaries.map(\.uid).max() ?? 0)
            }
        }
        guard list.isCurrent(selection, epoch), !Self.hasUnshownMail(status, page: list.mailbox[inbox]) else { return }
        var movedUp: [String] = []
        for (folder, folderStatus) in statuses
        where !list.mailbox.cachePainted.contains(folder) && !Self.hasUnshownMail(folderStatus, page: list.mailbox[folder]) {
            guard var page = list.mailbox[folder], page.fetchedAt.map({ $0 < checkedAt }) ?? true else { continue }
            page.fetchedAt = checkedAt
            list.mailbox[folder] = page
            movedUp.append(folder)
        }
        list.status.syncedAt = list.mailbox.syncedAt(of: list.targets)
        await noteSeenByPage(status)
        guard list.isCurrent(selection, epoch) else { return }
        let cache = list.writer.cache
        let writes = movedUp.compactMap { folder in
            list.mailbox[folder].map { page in
                let stored = MailboxPages.cachedCopy(of: page)
                return list.writer.chain { cache.savePage(stored, wipeCount: $0) }
            }
        }
        for write in writes { await write.value }
    }

    nonisolated static func hasUnshownMail(_ status: MailboxStatusInfo, page: MailFolderPage?) -> Bool {
        guard let page, page.uidValidity == status.uidValidity, let shown = page.uidNext else { return true }
        return status.uidNext > shown
    }

    private func prefetchArrivedBodies(after previousNewest: UInt32) async {
        guard let list else { return }
        let epoch = list.loads.accountEpoch
        let inbox = MailConstants.inbox
        guard list.loadState == .loaded, list.serverStatus == .ok, let page = list.mailbox[inbox] else { return }
        let validity = page.uidValidity
        let arrivals = page.summaries.map(\.uid).filter { $0 > previousNewest }
            .sorted(by: >).prefix(MailConstants.bodyPrefetchLimit)
        let cache = list.writer.cache
        for uid in arrivals {
            guard !Task.isCancelled, epoch == list.loads.accountEpoch else { return }
            let cached = await Task.detached { cache.loadDetail(folder: inbox, uidValidity: validity, uid: uid) }.value
            if cached != nil { continue }
            do {
                let detail = try await list.session.use { client in
                    try await client.detail(folder: inbox, uid: uid, expectedUIDValidity: validity, inlineImages: false)
                }
                guard epoch == list.loads.accountEpoch else { return }
                list.writer.chain { cache.saveDetail(detail, folder: inbox, uidValidity: validity, wipeCount: $0) }
            } catch let error as MailClientError where MailErrorClass(error).endsTheRun {
                return
            } catch {
                continue
            }
        }
    }

    /// Warms the folders the user is not looking at, so a chip tap paints from cache, not a
    /// spinner: the role folders in chip order, minus what the selection shows, at
    /// `MailConstants.warmPageSize` rows each, one at a time on the page's own connection, since
    /// Mail2000 caps connections. It writes only the cache, never shortens a cache the user paged
    /// further into, and stops at a lost connection: NTUST counts failed logins towards a lockout.
    private func startWarm() {
        guard let list else { return }
        warmTask?.cancel()
        warmDone = false
        var covered = Set(list.targets)
        let queue = MailFolderRole.allCases.compactMap { list.folderRoles[$0] }.filter { covered.insert($0).inserted }
        guard !queue.isEmpty else {
            warmTask = nil
            warmDone = true
            return
        }
        let epoch = list.loads.accountEpoch
        let delay = warmDelay
        let cache = list.writer.cache
        warmTask = Task { [weak self] in
            await delay()
            for folder in queue {
                guard !Task.isCancelled, let self, let list = self.list, list.loads.accountEpoch == epoch else { return }
                do {
                    var page = try await list.session.use { client in
                        try await client.page(folder: folder, olderThanSequence: nil, pageSize: MailConstants.warmPageSize)
                    }
                    page.fetchedAt = Date()
                    guard !Task.isCancelled, list.loads.accountEpoch == epoch else { return }
                    if list.targets.contains(folder) { continue }
                    await list.writer.chain { [page] wipeCount in
                        if Self.warmShouldWrite(page, over: cache.loadPage(folder: folder)) { cache.savePage(page, wipeCount: wipeCount) }
                    }.value
                } catch let error as MailClientError where MailErrorClass(error).endsTheRun {
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

    func startWarmIfLoaded() {
        guard let list else { return }
        guard !isPaused, list.loadState == .loaded, list.serverStatus == .ok else { return }
        startWarm()
    }

    /// Inbox and Sent first: most searches look there.
    func startIndexIfLoaded(for request: MailIndexer.Request? = nil) {
        guard let list else { return }
        guard !isPaused, list.loadState == .loaded, list.serverStatus == .ok, !list.folderRoles.isEmpty else { return }
        let roles = MailFolderRole.allCases.compactMap { list.folderRoles[$0] }
        indexer.startIfDue(folders: roles + list.otherFolders.filter { !roles.contains($0) }, for: request)
    }

    func cancelWarm() {
        warmTask?.cancel()
        warmTask = nil
    }

    nonisolated static func warmShouldWrite(_ page: MailFolderPage, over cached: MailFolderPage?) -> Bool {
        guard let cached, cached.uidValidity == page.uidValidity else { return true }
        return page.summaries.count >= cached.summaries.count
    }
}
#endif
