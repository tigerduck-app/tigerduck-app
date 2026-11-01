#if os(iOS)
import Foundation

@MainActor
enum MailListLoader {
    typealias Fetched = (pages: [(String, MailFolderPage)], failure: MailClientError?)

    /// Paints each covered folder's cached page first, then merges the newest page of each from
    /// the server into what is loaded: one round trip per covered folder however far the list was
    /// scrolled, since Mail2000 caps connections and answers "server busy" under load.
    static func load(list: MailListViewModel) async {
        var selection = list.selection
        let signIn = await list.account.startingSignIn
        guard list.loads.loadingSelection != selection else { return }
        list.loads.loadingSelection = selection
        defer {
            if signIn.isCurrent, list.loads.loadingSelection == selection { list.loads.loadingSelection = nil }
        }
        let token = list.mailbox.editToken
        if await paintFromCache(list: list) {
            list.status.loadState = .loaded
        } else if list.rows.isEmpty {
            list.status.loadState = .loading
        }
        list.status.isRefreshing = true
        defer {
            if list.isCurrent(selection, signIn), list.loads.loadingSelection == selection { list.status.isRefreshing = false }
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
                    list.loads.loadingSelection = selection
                }
                if await paintFromCache(list: list) { list.status.loadState = .loaded }
            }
            guard list.isCurrent(selection, signIn) else { return }
            let fetched = try await newestPages(of: list.targets, session: list.session)
            if fetched.failure == .authenticationFailed, signIn.isCurrent {
                list.session.reportAuthenticationRejection()
            }
            guard list.isCurrent(selection, signIn) else { return }
            for (folder, page) in fetched.pages {
                guard await merge(page, folder: folder, since: token, selection: selection, signIn: signIn, list: list) else { return }
            }
            list.rebuildRows()
            if let failure = fetched.failure { throw failure }
            list.status.serverStatus = .ok
            list.status.loadState = .loaded
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
    ) async -> Bool {
        if list.mailbox[folder]?.uidNext != fresh.uidNext { list.background.indexer.noteNewMail() }
        if let previous = list.mailbox[folder], previous.uidValidity != fresh.uidValidity {
            await list.writer.dropFolder(folder)
            list.mailbox.drop(folder)
            guard list.isCurrent(selection, signIn) else { return false }
        }
        var merged = list.mailbox.mergeFresh(fresh, folder: folder, since: token)
        list.rebuildRows()
        if merged.summaries.isEmpty, merged.messageCount > 0 {
            merged = list.mailbox.applyingEdits(to: await walkBack(from: merged, folder: folder, since: token, list: list),
                                                since: token)
        }
        guard list.isCurrent(selection, signIn) else { return false }
        await list.writer.save(merged)
        return true
    }

    private static func adoptDefaultSelection(list: MailListViewModel) -> Bool {
        guard !list.folders.wasChosen, list.selection != .allMail, list.showsAllMailChip else { return false }
        list.folders.selection = .allMail
        return true
    }

    private static func paintFromCache(list: MailListViewModel) async -> Bool {
        var painted = false
        for folder in list.targets where list.mailbox[folder] == nil {
            if let cached = await list.writer.cachedPage(folder: folder) {
                list.mailbox[folder] = cached
                list.mailbox.cachePainted.insert(folder)
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
            return (pages, failure)
        }
        let fetchedAt = Date()
        let pages = fetched.pages.map { folder, page in
            var fresh = page
            fresh.fetchedAt = fetchedAt
            return (folder, fresh)
        }
        return (pages, fetched.failure)
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
            current = list.mailbox.applyingEdits(to: MailFolderPage(
                folder: current.folder, uidValidity: current.uidValidity, messageCount: current.messageCount,
                summaries: older.summaries.sorted { $0.uid > $1.uid },
                oldestLoadedSequence: older.oldestLoadedSequence, uidNext: current.uidNext,
                fetchedAt: current.fetchedAt
            ), since: token)
            list.setPage(current, folder: folder)
        }
        return current
    }

    static func loadOlder(list: MailListViewModel) async {
        let selection = list.selection
        let signIn = await list.account.startingSignIn
        let token = list.mailbox.editToken
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
                    list.setPage(list.mailbox.applyingEdits(to: merged, since: token), folder: folder)
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
