#if os(iOS)
import Foundation

@MainActor
enum MailListLoader {
    struct Fetched: MailCaughtRejection {
        var pages: [(String, MailFolderPage)]
        var failure: MailClientError?
        var rejectedPassword: Bool { failure == .authenticationFailed }
    }

    private enum Merge { case merged, superseded }

    /// Paints each covered folder's cached page first, then merges the newest page of each from
    /// the server into what is loaded: one round trip per covered folder however far the list was
    /// scrolled, since Mail2000 caps connections and answers "server busy" under load.
    static func load(list: MailListViewModel) async {
        var selection = list.selection
        let signIn = await list.account.startingSignIn
        guard list.loads.inFlight?.selection != selection else { return }
        let load = MailListLoads.InFlight(selection: selection)
        list.loads.inFlight = load
        defer {
            if list.loads.inFlight?.id == load.id { list.loads.inFlight = nil }
        }
        let token = list.mailbox.lastEdit
        if await paintFromCache(list: list) {
            list.status.loadState = .loaded
        } else if list.rows.isEmpty {
            list.status.loadState = .loading
        }
        list.status.isRefreshing = true
        defer {
            if list.loads.inFlight?.id == load.id, selection == list.selection { list.status.isRefreshing = false }
        }
        do {
            if list.folders.roles.isEmpty {
                let available = try await list.session.use { client in try await client.listFolders() }
                guard signIn.isCurrent else { return }
                list.folders.roles = MailFolderMap.resolve(available: available)
                list.folders.others = MailFolderMap.otherFolders(available: available)
                guard list.isCurrent(selection, signIn) else { return }
                if adoptDefaultSelection(list: list) {
                    selection = list.selection
                    list.loads.inFlight?.selection = selection
                }
                if await paintFromCache(list: list) { list.status.loadState = .loaded }
            }
            guard list.isCurrent(selection, signIn) else { return }
            let fetched = try await newestPages(of: list.targets, session: list.session)
            guard list.isCurrent(selection, signIn) else { return }
            for (folder, page) in fetched.pages {
                let merge = await merge(page, folder: folder, since: token, selection: selection, signIn: signIn, list: list)
                guard merge == .merged else { return }
            }
            list.rebuildRows()
            if let failure = fetched.failure { throw failure }
            list.status.serverStatus = .ok
            list.status.loadState = .loaded
            await learnFlagStorage(list: list, signIn: signIn)
            list.background.startIndexIfLoaded()
        } catch {
            guard list.isCurrent(selection, signIn) else { return }
            list.status.serverStatus = .failed
            list.status.loadState = list.rows.isEmpty ? .failed(MailAccountManager.LoginError(error).message) : .loaded
        }
    }

    private static func merge(
        _ fresh: MailFolderPage, folder: String, since token: EditToken, selection: MailFolderSelection, signIn: SignIn,
        list: MailListViewModel
    ) async -> Merge {
        if list.mailbox[folder]?.uidNext != fresh.uidNext { list.background.indexer.noteNewMail() }
        if let previous = list.mailbox[folder], previous.uidValidity != fresh.uidValidity {
            await list.writer.dropFolder(folder)
            list.mailbox.drop(folder)
            guard list.isCurrent(selection, signIn) else { return .superseded }
        }
        var merged = list.mailbox.mergeFresh(fresh, folder: folder, since: token)
        list.rebuildRows()
        if merged.summaries.isEmpty, merged.messageCount > 0 {
            merged = list.mailbox.replayingEdits(onto: await walkBack(from: merged, folder: folder, since: token, list: list),
                                                madeAfter: token)
        }
        guard list.isCurrent(selection, signIn) else { return .superseded }
        await list.writer.save(merged).value
        return .merged
    }

    private static func learnFlagStorage(list: MailListViewModel, signIn: SignIn) async {
        let unknown = list.targets.filter { list.folders.storesFlagged[$0] == nil }
        guard !unknown.isEmpty, let found = try? await list.session.use(for: signIn, { client -> [String: Bool] in
            var found: [String: Bool] = [:]
            for folder in unknown { found[folder] = try await client.storesFlagged(folder: folder) }
            return found
        }), signIn.isCurrent else { return }
        list.folders.storesFlagged.merge(found) { $1 }
    }

    private static func adoptDefaultSelection(list: MailListViewModel) -> Bool {
        guard !list.folders.pickedByUser, list.selection != .allMail, list.showsAllMailChip else { return false }
        list.folders.selection = .allMail
        return true
    }

    private static func paintFromCache(list: MailListViewModel) async -> Bool {
        var painted = false
        for folder in list.targets where list.mailbox[folder] == nil {
            if let cached = await list.writer.cachedPage(folder: folder) {
                list.mailbox[folder] = cached
                list.mailbox.cachedNotRefreshed.insert(folder)
                painted = true
            }
        }
        if painted { list.rebuildRows() }
        return painted
    }

    static func newestPages(of folders: [String], session: MailPageSession) async throws -> Fetched {
        let fetched = try await session.use { client -> Fetched in
            var pages: [(String, MailFolderPage)] = []
            var failure: MailClientError?
            for folder in folders {
                do {
                    pages.append((folder, try await client.page(folder: folder, olderThanSequence: nil,
                                                                pageSize: MailConstants.pageSize)))
                } catch let error as MailClientError {
                    failure = error
                    if MailErrorClass(error).endsTheRun { break }
                }
            }
            return Fetched(pages: pages, failure: failure)
        }
        let fetchedAt = Date()
        let pages = fetched.pages.map { folder, page in
            var fresh = page
            fresh.fetchedAt = fetchedAt
            return (folder, fresh)
        }
        return Fetched(pages: pages, failure: fetched.failure)
    }

    static func walkBack(
        from start: MailFolderPage, folder: String, since token: EditToken, list: MailListViewModel
    ) async -> MailFolderPage {
        var current = start
        var fetched = 0
        let selection = list.selection
        let signIn = await list.account.startingSignIn
        while current.summaries.isEmpty, let cursor = current.oldestLoadedSequence,
              fetched < MailConstants.emptyWindowWalkbackPages {
            fetched += 1
            guard let older = try? await list.session.use({ client in
                try await client.page(folder: folder, olderThanSequence: cursor, pageSize: MailConstants.pageSize)
            }) else { break }
            guard list.isCurrent(selection, signIn), older.uidValidity == current.uidValidity else { break }
            current = list.mailbox.replayingEdits(onto: MailFolderPage(
                folder: current.folder, uidValidity: current.uidValidity, messageCount: current.messageCount,
                summaries: older.summaries.sorted { $0.uid > $1.uid },
                oldestLoadedSequence: older.oldestLoadedSequence, uidNext: current.uidNext,
                fetchedAt: current.fetchedAt
            ), madeAfter: token)
            list.setPage(current, folder: folder)
        }
        return current
    }

    static func loadOlder(list: MailListViewModel) async {
        let selection = list.selection
        let signIn = await list.account.startingSignIn
        let token = list.mailbox.lastEdit
        let cursors = list.targets.compactMap { folder in list.mailbox[folder]?.oldestLoadedSequence.map { (folder, $0) } }
        guard !cursors.isEmpty else { return }
        list.status.isPaginating = true
        defer { list.status.isPaginating = false }
        for (folder, first) in cursors {
            var cursor: Int? = first
            var extraPages = 0
            while let older = cursor {
                do {
                    let next = try await list.session.use { client in
                        try await client.page(folder: folder, olderThanSequence: older, pageSize: MailConstants.pageSize)
                    }
                    guard list.isCurrent(selection, signIn), let page = list.mailbox[folder] else { return }
                    guard next.uidValidity == page.uidValidity else {
                        await list.recoverFromFolderChange(folder)
                        return
                    }
                    let lowest = page.summaries.map(\.uid).min()
                    let merged = MailboxPages.mergeOlder(next, into: page)
                    list.setPage(list.mailbox.replayingEdits(onto: merged, madeAfter: token), folder: folder)
                    let addedOlder = lowest.map { lowest in merged.summaries.contains { $0.uid < lowest } } ?? !merged.summaries.isEmpty
                    if addedOlder || extraPages == MailConstants.emptyWindowWalkbackPages {
                        cursor = nil
                    } else {
                        cursor = next.oldestLoadedSequence
                        extraPages += 1
                    }
                } catch MailClientError.folderChanged {
                    await list.recoverFromFolderChange(folder)
                    return
                } catch {
                    guard list.isCurrent(selection, signIn) else { return }
                    list.status.serverStatus = .failed
                    return
                }
            }
        }
    }
}
#endif
