#if os(iOS)
import Foundation
import Observation

/// The list's search: its matches from the local index and the loaded mail, fetched a page at a
/// time, and the matches a running index pass adds while the results are on screen.
@MainActor
@Observable
final class MailListSearch {
    typealias Matches = (uidValidity: UInt32, uids: [UInt32])

    /// The search under way moves `current`; `shown` is the one `results` shows.
    private struct Generations {
        var current = 0
        var shown = -1
    }

    var text = ""
    private(set) var results: [MailListRow]?
    private(set) var usedLocalFallback = false
    /// The query of the search under way or shown; empty when there is none.
    @ObservationIgnored private var query = ""
    @ObservationIgnored private var known = MailSearchKnown()
    @ObservationIgnored private var generations = Generations()
    @ObservationIgnored private var indexLookup: Task<Matches?, Never>?
    @ObservationIgnored let catchUp: MailSearchCatchUp
    /// Weak: a catch-up task outlives the list it searched once the page closes.
    @ObservationIgnored private weak var list: MailListViewModel?

    init(list: MailListViewModel, catchUpDelay: @escaping @Sendable () async -> Void) {
        self.list = list
        catchUp = MailSearchCatchUp(delay: catchUpDelay)
    }

    var isShowingResults: Bool { results != nil }

    func submit() async {
        guard let list else { return }
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            clear()
            return
        }
        let selection = list.selection
        let epoch = list.loads.accountEpoch
        supersede()
        self.query = query
        let generation = generations.current
        var found: [MailListRow] = []
        var unfetched: [String: Matches] = [:]
        var usedFallback = false
        var serverFailed = false
        var recreated: [String] = []
        for folder in list.targets {
            guard !Task.isCancelled, generation == generations.current else { return }
            let matched = await matchingUIDs(in: folder, query: query)
            guard !Task.isCancelled, list.isCurrent(selection, epoch), generation == generations.current else { return }
            guard let matched, !matched.uids.isEmpty else { continue }
            let validity = matched.uidValidity
            let newest = Array(matched.uids.prefix(MailConstants.pageSize))
            do {
                let summaries = try await list.session.use { client in
                    try await client.summaries(folder: folder, uids: newest, expectedUIDValidity: validity)
                }
                guard list.isCurrent(selection, epoch), generation == generations.current else { return }
                known.noteGone(newest, summaries, folder: folder)
                found += summaries.filter { !$0.isDeleted }.map { MailListRow(folder: folder, summary: $0) }
                unfetched[folder] = (validity, Array(matched.uids.dropFirst(newest.count)))
            } catch MailClientError.folderChanged {
                guard list.isCurrent(selection, epoch) else { return }
                recreated.append(folder)
            } catch {
                guard list.isCurrent(selection, epoch) else { return }
                serverFailed = true
                let uids = Set(matched.uids)
                found += (list.mailbox[folder]?.summaries ?? []).filter { uids.contains($0.uid) }
                    .map { MailListRow(folder: folder, summary: $0) }
                // The rows' validity, so a catch-up can tell they predate a recreated folder.
                unfetched[folder] = (validity, [])
                usedFallback = true
            }
        }
        guard list.isCurrent(selection, epoch), generation == generations.current else { return }
        if serverFailed { list.status.serverStatus = .failed }
        results = list.ordered(found)
        generations.shown = generation
        known.unfetched = unfetched
        usedLocalFallback = usedFallback
        for folder in recreated { await list.recoverFromFolderChange(folder) }
        if list.displayedRows.isEmpty { await loadMore() }
        guard generation == generations.current else { return }
        if catchUp.isBehind { scheduleCatchUp() }
        // A folder the index has not caught up with is downloaded now; its matches join as they arrive.
        if list.targets.contains(where: { !list.background.indexer.isIndexed($0) }) { list.background.startIndexIfLoaded(for: .search) }
    }

    /// `folder`'s mail that matches `query`, newest first: the index's, and the loaded mail's, which
    /// may have arrived since the index last caught up. Nil when neither knows the folder.
    private func matchingUIDs(in folder: String, query: String) async -> Matches? {
        guard let list else { return nil }
        let lookup = Task.detached { [index = list.writer.cache.searchIndex] in index.search(folder: folder, query: query) }
        indexLookup = lookup
        let indexed = await lookup.value
        let page = list.mailbox[folder]
        guard let validity = page?.uidValidity ?? indexed?.uidValidity else { return nil }
        var matched = Set(indexed?.uidValidity == validity ? indexed?.uids ?? [] : [])
        matched.formUnion((page?.summaries ?? []).filter { $0.matchesSearch(query) }.map(\.uid))
        return (validity, matched.sorted(by: >))
    }

    /// A pass that fills a folder the search covers adds its new matches to the results, at most
    /// once per catch-up delay, so the last fill's are added after the pass ends.
    func indexDidFill(_ folder: String) {
        guard let list else { return }
        guard !query.isEmpty, list.targets.contains(folder) else { return }
        catchUp.isBehind = true
        if generations.shown == generations.current { scheduleCatchUp() }
    }

    /// The page reopening runs the catch-up a closed page left behind.
    func resumeCatchUp() {
        if catchUp.isBehind, generations.shown == generations.current { scheduleCatchUp() }
    }

    private func scheduleCatchUp() {
        guard let list else { return }
        guard !list.background.isPaused else { return }
        let generation = generations.current
        catchUp.schedule(
            isCurrent: { [weak self] in
                guard let self, let list = self.list else { return false }
                return !list.background.isPaused && generation == self.generations.current
            },
            run: { [weak self] in await self?.catchUpResults() ?? false },
            stillCurrent: { [weak self] in generation == self?.generations.current }
        )
    }

    /// Adds the matches the index gained since the search ran, leaving the listed rows in place:
    /// a folder's matches newer than its oldest listed row are fetched now, with older ones only
    /// to fill its first page, and the rest wait for the end of the list. False when it stopped
    /// before the last folder.
    private func catchUpResults() async -> Bool {
        guard let list else { return false }
        let query = self.query
        let selection = list.selection
        let epoch = list.loads.accountEpoch
        let generation = generations.current
        for folder in list.targets {
            let matched = await matchingUIDs(in: folder, query: query)
            guard !Task.isCancelled, list.isCurrent(selection, epoch), generation == generations.current,
                  results != nil else { return false }
            guard let matched else { continue }
            if let known = known.unfetched[folder], known.uidValidity != matched.uidValidity {
                // The folder was recreated, so its old uids may name other mail now.
                results?.removeAll { $0.folder == folder }
                self.known.gone[folder] = nil
            }
            let listed = Set((results ?? []).filter { $0.folder == folder }.map(\.uid))
            let batch = known.nextBatch(of: matched, folder: folder, listed: listed)
            guard !batch.isEmpty else { continue }
            guard await fetch(batch, folder: folder, uidValidity: matched.uidValidity,
                              selection: selection, epoch: epoch, generation: generation) else { return false }
        }
        // Under the unread filter every row added can be read, and an empty list has no row whose
        // appearance asks for the next page.
        guard !Task.isCancelled, list.isCurrent(selection, epoch), generation == generations.current else { return false }
        if list.displayedRows.isEmpty, !list.isPaginating { await loadMore() }
        return true
    }

    /// Adds `batch` of `folder`'s matches to the results; false when the search stopped there.
    private func fetch(
        _ batch: [UInt32], folder: String, uidValidity: UInt32,
        selection: MailFolderSelection, epoch: Int, generation: Int
    ) async -> Bool {
        guard let list else { return false }
        do {
            let summaries = try await list.session.use { client in
                try await client.summaries(folder: folder, uids: batch, expectedUIDValidity: uidValidity)
            }
            guard list.isCurrent(selection, epoch), generation == generations.current, let current = results else {
                return false
            }
            known.noteGone(batch, summaries, folder: folder)
            // Only what this fetch asked for: a catch-up may have queued more meanwhile.
            known.unfetched[folder]?.uids.removeAll { batch.contains($0) }
            let shown = Set(current.map(\.id))
            let rows = summaries.filter { !$0.isDeleted }.map { MailListRow(folder: folder, summary: $0) }
                .filter { !shown.contains($0.id) }
            if !rows.isEmpty { results = list.ordered(current + rows) }
            return true
        } catch MailClientError.folderChanged {
            guard list.isCurrent(selection, epoch), generation == generations.current else { return false }
            known.unfetched[folder] = nil
            results?.removeAll { $0.folder == folder }
            await list.recoverFromFolderChange(folder)
            return false
        } catch {
            // A stop, as the page closing, can be what failed it; the server is not to blame.
            guard !Task.isCancelled, list.isCurrent(selection, epoch) else { return false }
            list.status.serverStatus = .failed
            return false
        }
    }

    func loadMore() async {
        guard let list else { return }
        let selection = list.selection
        let epoch = list.loads.accountEpoch
        let generation = generations.current
        let end = list.displayedRows.last?.id
        list.status.isPaginating = true
        defer { list.status.isPaginating = false }
        while list.displayedRows.last?.id == end {
            let pending = known.unfetched.filter { !$0.value.uids.isEmpty }
            guard !pending.isEmpty else { return }
            for (folder, matches) in pending {
                // A stopped catch-up or a closed page fetches no further page; the reopening's
                // catch-up pages on, since an empty unread-only list has no row to ask for it.
                guard !Task.isCancelled, !list.background.isPaused else {
                    if list.background.isPaused, generation == generations.current { catchUp.isBehind = true }
                    return
                }
                let batch = Array(matches.uids.prefix(MailConstants.pageSize))
                guard await fetch(batch, folder: folder, uidValidity: matches.uidValidity,
                                  selection: selection, epoch: epoch, generation: generation) else { return }
            }
        }
    }

    func clear() {
        supersede()
        query = ""
        results = nil
        usedLocalFallback = false
    }

    /// Also stops the scan of the index under way, which holds the lock its download writes under.
    private func supersede() {
        generations.current += 1
        indexLookup?.cancel()
        catchUp.cancel()
        catchUp.isBehind = false
        known.gone = [:]
    }

    func markSeen(folder: String, uid: UInt32, seen: Bool) {
        if let index = results?.firstIndex(where: { $0.folder == folder && $0.uid == uid }) {
            results?[index].summary.isSeen = seen
        }
    }

    func remove(folder: String, uid: UInt32) {
        results?.removeAll { $0.folder == folder && $0.uid == uid }
    }
}

/// Per folder, the matches not fetched yet, and those the server listed as deleted or no longer
/// had, which the catch-ups leave out rather than fetch again.
struct MailSearchKnown {
    var unfetched: [String: MailListSearch.Matches] = [:]
    var gone: [String: Set<UInt32>] = [:]

    /// Records the `requested` mail the server answered as deleted or not at all.
    mutating func noteGone(_ requested: [UInt32], _ summaries: [MailSummary], folder: String) {
        let kept = Set(summaries.filter { !$0.isDeleted }.map(\.uid))
        gone[folder, default: []].formUnion(requested.filter { !kept.contains($0) })
    }

    /// Keeps `folder`'s matches not listed or gone, and returns those to fetch now: the ones newer
    /// than the oldest listed row, and older ones only to fill the folder's first page.
    mutating func nextBatch(of matched: MailListSearch.Matches, folder: String, listed: Set<UInt32>) -> [UInt32] {
        let skipped = listed.union(gone[folder] ?? [])
        let waiting = matched.uids.filter { !skipped.contains($0) }
        let oldestListed = listed.min() ?? .max
        let wanted = waiting.prefix { $0 > oldestListed }.count + max(0, MailConstants.pageSize - listed.count)
        unfetched[folder] = (matched.uidValidity, waiting)
        return Array(waiting.prefix(min(wanted, MailConstants.pageSize)))
    }
}

private extension MailSummary {
    func matchesSearch(_ query: String) -> Bool {
        [subject, fromName, fromAddress].contains { $0?.localizedCaseInsensitiveContains(query) == true }
    }
}

/// Adds an index pass's new matches to the results at most once per `delay`, so the last fill's
/// are added after the pass ends.
@MainActor
final class MailSearchCatchUp {
    /// The index holds matches the results do not show yet.
    var isBehind = false
    private let delay: @Sendable () async -> Void
    private var task: Task<Void, Never>?

    init(delay: @escaping @Sendable () async -> Void) {
        self.delay = delay
    }

    /// `run` returns false when it stopped, which leaves the rest for the next fill or the page
    /// reopening rather than a retry at once.
    func schedule(isCurrent: @escaping () -> Bool, run: @escaping () async -> Bool, stillCurrent: @escaping () -> Bool) {
        guard task == nil else { return }
        let delay = self.delay
        task = Task { [weak self] in
            await delay()
            while let self, !Task.isCancelled, isCurrent(), self.isBehind {
                self.isBehind = false
                guard await run() else {
                    if stillCurrent() { self.isBehind = true }
                    break
                }
                await delay()
            }
            guard let self, !Task.isCancelled, stillCurrent() else { return }
            self.task = nil
        }
    }

    /// A catch-up's fetch would open the connection again, so a closed page leaves it for its
    /// reopening.
    func pause() {
        if task != nil { isBehind = true }
        cancel()
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func wait() async {
        await task?.value
    }
}
#endif
