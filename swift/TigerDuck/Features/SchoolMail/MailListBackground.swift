#if os(iOS)
import Foundation

@MainActor
final class MailListBackground {
    let indexer: MailIndexer
    private(set) var isPaused = false
    private var pollTask: Task<Void, Never>?
    private let noteSeenByPage: (MailboxStatusInfo, SignIn) async -> Void
    private var warmTask: Task<Void, Never>?
    private var warmDone = false
    private let warmDelay: @Sendable () async -> Void
    private weak var list: MailListViewModel?

    init(
        list: MailListViewModel, indexer: MailIndexer, noteSeenByPage: @escaping (MailboxStatusInfo, SignIn) async -> Void,
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

    func reset() {
        cancelWarm()
        indexer.reset()
        warmDone = false
    }

    func waitForWarm() async { await warmTask?.value }

    var isIndexBusy: Bool { !indexer.isComplete || indexer.isDownloading }

    func pollOnce() async {
        guard let list else { return }
        guard list.showsInbox, !list.search.isShowingResults else { return }
        let selection = list.selection
        let signIn = await list.account.startingSignIn
        let inbox = MailConstants.inbox
        let folders = list.targets
        guard let statuses = try? await list.session.use({ client -> [String: MailboxStatusInfo] in
                  var result = [inbox: try await client.status(folder: inbox)]
                  for folder in folders where folder != inbox {
                      result[folder] = try? await client.status(folder: folder)
                  }
                  return result
              }),
              let status = statuses[inbox], list.isCurrent(selection, signIn), !list.search.isShowingResults else { return }
        let checkedAt = Date()
        let before = list.mailbox[inbox]
        if statuses.contains(where: { Self.hasUnshownMail($0.value, page: list.mailbox[$0.key]) }) {
            await list.load()
            guard list.isCurrent(selection, signIn) else { return }
            if let before, before.uidValidity == status.uidValidity {
                await prefetchArrivedBodies(after: before.summaries.map(\.uid).max() ?? 0)
            }
        }
        guard list.isCurrent(selection, signIn), !Self.hasUnshownMail(status, page: list.mailbox[inbox]) else { return }
        var movedUp: [String] = []
        for (folder, folderStatus) in statuses
        where !list.mailbox.cachedNotRefreshed.contains(folder) && !Self.hasUnshownMail(folderStatus, page: list.mailbox[folder]) {
            guard var page = list.mailbox[folder], page.fetchedAt.map({ $0 < checkedAt }) ?? true else { continue }
            page.fetchedAt = checkedAt
            list.mailbox[folder] = page
            movedUp.append(folder)
        }
        list.status.syncedAt = list.mailbox.syncedAt(of: list.targets)
        await noteSeenByPage(status, signIn)
        guard list.isCurrent(selection, signIn) else { return }
        let writes = movedUp.compactMap { list.mailbox[$0].map(list.writer.save) }
        for write in writes { await write.value }
    }

    nonisolated static func hasUnshownMail(_ status: MailboxStatusInfo, page: MailFolderPage?) -> Bool {
        guard let page, page.uidValidity == status.uidValidity, let shown = page.uidNext else { return true }
        return status.uidNext > shown
    }

    private func prefetchArrivedBodies(after previousNewest: UInt32) async {
        guard let list else { return }
        let signIn = await list.account.startingSignIn
        let inbox = MailConstants.inbox
        guard list.loadState == .loaded, list.serverStatus == .ok, let page = list.mailbox[inbox] else { return }
        let validity = page.uidValidity
        let arrivals = page.summaries.map(\.uid).filter { $0 > previousNewest }
            .sorted(by: >).prefix(MailConstants.bodyPrefetchLimit)
        let cache = list.writer.cache
        for uid in arrivals {
            guard !Task.isCancelled, signIn.isCurrent else { return }
            let cached = await Task.detached { cache.loadDetail(folder: inbox, uidValidity: validity, uid: uid) }.value
            if cached != nil { continue }
            do {
                let detail = try await list.session.use { client in
                    try await client.detail(folder: inbox, uid: uid, expectedUIDValidity: validity, inlineImages: false)
                }
                guard signIn.isCurrent else { return }
                list.writer.enqueue { cache.saveDetail(detail, folder: inbox, uidValidity: validity, unlessWipedSince: $0) }
            } catch let error as MailClientError where MailErrorClass(error).endsTheRun {
                return
            } catch {
                continue
            }
        }
    }

    private func startWarm() {
        guard let list else { return }
        warmTask?.cancel()
        warmDone = false
        let queue = Self.warmQueue(roles: list.folderRoles, shown: list.targets)
        guard !queue.isEmpty else {
            warmTask = nil
            warmDone = true
            return
        }
        let signIn = list.account.currentSignIn
        let delay = warmDelay
        let cache = list.writer.cache
        warmTask = Task { [weak self] in
            await delay()
            var warmed = true
            warming: for folder in queue {
                guard !Task.isCancelled, let self, let list = self.list else { return }
                // A sign-in that ended stops the warm, which a later page visit starts again.
                guard signIn.isCurrent else {
                    warmed = false
                    break
                }
                do {
                    var page = try await list.session.use { client in
                        try await client.page(folder: folder, olderThanSequence: nil, pageSize: MailConstants.warmPageSize)
                    }
                    page.fetchedAt = Date()
                    guard !Task.isCancelled else { return }
                    guard signIn.isCurrent else {
                        warmed = false
                        break warming
                    }
                    if list.targets.contains(folder) { continue }
                    await list.writer.enqueue { [page] wipeCount in
                        if Self.warmShouldWrite(page, over: cache.loadPage(folder: folder)) { cache.savePage(page, unlessWipedSince: wipeCount) }
                    }.value
                } catch let error as MailClientError where MailErrorClass(error).endsTheRun {
                    return
                } catch {
                    continue
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.warmDone = warmed
            self.warmTask = nil
        }
    }

    func pausingWarm(during load: () async -> Void) async {
        cancelWarm()
        await load()
        startWarmIfLoaded()
    }

    func startWarmIfLoaded() {
        guard let list else { return }
        guard !isPaused, list.loadState == .loaded, list.serverStatus == .ok else { return }
        startWarm()
    }

    func startIndexIfLoaded(for request: MailIndexer.Request? = nil) {
        guard let list else { return }
        guard !isPaused, list.loadState == .loaded, list.serverStatus == .ok, !list.folderRoles.isEmpty else { return }
        let roles = MailFolderRole.listOrder.compactMap { list.folderRoles[$0] }
        indexer.startIfDue(folders: roles + list.otherFolders.filter { !roles.contains($0) }, for: request)
    }

    func cancelWarm() {
        warmTask?.cancel()
        warmTask = nil
    }

    private static func warmQueue(roles: [MailFolderRole: String], shown: [String]) -> [String] {
        var queued = Set(shown)
        return MailFolderRole.listOrder.compactMap { roles[$0] }.filter { queued.insert($0).inserted }
    }

    nonisolated static func warmShouldWrite(_ page: MailFolderPage, over cached: MailFolderPage?) -> Bool {
        guard let cached, cached.uidValidity == page.uidValidity else { return true }
        return page.summaries.count >= cached.summaries.count
    }
}
#endif
