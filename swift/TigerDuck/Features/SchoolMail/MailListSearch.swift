#if os(iOS)
import Foundation
import Observation

@MainActor
@Observable
final class MailListSearch {
    typealias Matches = (uidValidity: UInt32, uids: [UInt32])

    private struct Generations {
        var latest = 0
        var displayed = -1
    }

    private enum Fetch { case shown, stopped }

    var text = ""
    private(set) var results: [MailListRow]?
    private(set) var usedLocalFallback = false
    @ObservationIgnored private var query = ""
    @ObservationIgnored private var known = MailSearchFetchState()
    @ObservationIgnored private var generations = Generations()
    @ObservationIgnored private var indexLookup: Task<Matches?, Never>?
    @ObservationIgnored let catchUp: MailSearchCatchUp
    @ObservationIgnored private weak var list: MailListViewModel?

    init(list: MailListViewModel, catchUpDelay: @escaping @Sendable () async -> Void) {
        self.list = list
        catchUp = MailSearchCatchUp(delay: catchUpDelay)
    }

    var isShowingResults: Bool { results != nil }

    var indexProgress: MailIndexProgress? {
        guard let list, isShowingResults else { return nil }
        let indexer = list.background.indexer
        guard list.targets.contains(where: { !indexer.isIndexed($0) }) else { return nil }
        return indexer.progress
    }

    func submit() async {
        guard let list else { return }
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            clear()
            return
        }
        let selection = list.selection
        let signIn = await list.account.startingSignIn
        supersede()
        self.query = query
        let generation = generations.latest
        var found: [MailListRow] = []
        var unfetched: [String: Matches] = [:]
        var usedFallback = false
        var serverFailed = false
        var recreated: [String] = []
        for folder in list.targets {
            guard !Task.isCancelled, generation == generations.latest else { return }
            let matched = await indexedAndLoadedMatches(in: folder, query: query)
            guard !Task.isCancelled, list.isCurrent(selection, signIn), generation == generations.latest else { return }
            guard let matched, !matched.uids.isEmpty else { continue }
            let validity = matched.uidValidity
            let newest = Array(matched.uids.prefix(MailConstants.pageSize))
            do {
                let summaries = try await list.session.use { client in
                    try await client.summaries(folder: folder, uids: newest, expectedUIDValidity: validity)
                }
                guard list.isCurrent(selection, signIn), generation == generations.latest else { return }
                known.noteGone(newest, summaries, folder: folder)
                found += summaries.filter { !$0.isDeleted }.map { MailListRow(folder: folder, summary: $0) }
                unfetched[folder] = (validity, Array(matched.uids.dropFirst(newest.count)))
            } catch MailClientError.folderChanged {
                guard list.isCurrent(selection, signIn) else { return }
                recreated.append(folder)
            } catch {
                guard list.isCurrent(selection, signIn) else { return }
                serverFailed = true
                let uids = Set(matched.uids)
                found += (list.mailbox[folder]?.summaries ?? []).filter { uids.contains($0.uid) }
                    .map { MailListRow(folder: folder, summary: $0) }
                unfetched[folder] = (validity, [])
                usedFallback = true
            }
        }
        guard list.isCurrent(selection, signIn), generation == generations.latest else { return }
        if serverFailed { list.status.serverStatus = .failed }
        results = list.ordered(found)
        generations.displayed = generation
        known.unfetched = unfetched
        usedLocalFallback = usedFallback
        for folder in recreated { await list.recoverFromFolderChange(folder) }
        if list.displayedRows.isEmpty { await loadMore() }
        guard generation == generations.latest else { return }
        if catchUp.isBehind { scheduleCatchUp() }
        if list.targets.contains(where: { !list.background.indexer.isIndexed($0) }) { list.background.startIndexIfLoaded(for: .search) }
    }

    private func indexedAndLoadedMatches(in folder: String, query: String) async -> Matches? {
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

    func indexDidFill(_ folder: String) {
        guard let list else { return }
        guard !query.isEmpty, list.targets.contains(folder) else { return }
        catchUp.isBehind = true
        if generations.displayed == generations.latest { scheduleCatchUp() }
    }

    func resumeCatchUp() {
        if catchUp.isBehind, generations.displayed == generations.latest { scheduleCatchUp() }
    }

    private func scheduleCatchUp() {
        guard let list else { return }
        guard !list.background.isPaused else { return }
        let generation = generations.latest
        catchUp.schedule(
            canRun: { [weak self] in self?.list.map { !$0.background.isPaused } ?? false },
            run: { [weak self] in await self?.catchUpResults(for: generation) ?? .superseded }
        )
    }

    private func catchUpResults(for generation: Int) async -> MailCatchUpPass {
        guard let list, generation == generations.latest else { return .superseded }
        let query = self.query
        let selection = list.selection
        let signIn = await list.account.startingSignIn
        for folder in list.targets {
            let matched = await indexedAndLoadedMatches(in: folder, query: query)
            guard !Task.isCancelled, list.isCurrent(selection, signIn), generation == generations.latest,
                  results != nil else { return stoppedPass(generation) }
            guard let matched else { continue }
            if let known = known.unfetched[folder], known.uidValidity != matched.uidValidity {
                results?.removeAll { $0.folder == folder }
                self.known.gone[folder] = nil
            }
            let listed = Set((results ?? []).filter { $0.folder == folder }.map(\.uid))
            let waiting = known.waiting(in: matched, folder: folder, listed: listed)
            known.unfetched[folder] = (matched.uidValidity, waiting)
            let batch = MailSearchFetchState.nextBatch(of: waiting, listed: listed)
            guard !batch.isEmpty else { continue }
            let fetched = await fetch(batch, folder: folder, uidValidity: matched.uidValidity,
                                      selection: selection, signIn: signIn, generation: generation)
            guard fetched == .shown else { return stoppedPass(generation) }
        }
        guard !Task.isCancelled, list.isCurrent(selection, signIn), generation == generations.latest else {
            return stoppedPass(generation)
        }
        if list.displayedRows.isEmpty, !list.isPaginating { await loadMore() }
        return .caughtUp
    }

    private func stoppedPass(_ generation: Int) -> MailCatchUpPass {
        generation == generations.latest ? .stopped : .superseded
    }

    private func fetch(
        _ batch: [UInt32], folder: String, uidValidity: UInt32,
        selection: MailFolderSelection, signIn: SignIn, generation: Int
    ) async -> Fetch {
        guard let list else { return .stopped }
        do {
            let summaries = try await list.session.use { client in
                try await client.summaries(folder: folder, uids: batch, expectedUIDValidity: uidValidity)
            }
            guard list.isCurrent(selection, signIn), generation == generations.latest, let current = results else {
                return .stopped
            }
            known.noteGone(batch, summaries, folder: folder)
            known.unfetched[folder]?.uids.removeAll { batch.contains($0) }
            let shown = Set(current.map(\.id))
            let rows = summaries.filter { !$0.isDeleted }.map { MailListRow(folder: folder, summary: $0) }
                .filter { !shown.contains($0.id) }
            if !rows.isEmpty { results = list.ordered(current + rows) }
            return .shown
        } catch MailClientError.folderChanged {
            guard list.isCurrent(selection, signIn), generation == generations.latest else { return .stopped }
            known.unfetched[folder] = nil
            results?.removeAll { $0.folder == folder }
            await list.recoverFromFolderChange(folder)
            return .stopped
        } catch {
            guard !Task.isCancelled, list.isCurrent(selection, signIn) else { return .stopped }
            list.status.serverStatus = .failed
            return .stopped
        }
    }

    func loadMore() async {
        guard let list else { return }
        let selection = list.selection
        let signIn = await list.account.startingSignIn
        let generation = generations.latest
        let end = list.displayedRows.last?.id
        list.status.isPaginating = true
        defer { list.status.isPaginating = false }
        while list.displayedRows.last?.id == end {
            let pending = known.unfetched.filter { !$0.value.uids.isEmpty }
            guard !pending.isEmpty else { return }
            for (folder, matches) in pending {
                guard !Task.isCancelled, !list.background.isPaused else {
                    if list.background.isPaused, generation == generations.latest { catchUp.isBehind = true }
                    return
                }
                let batch = Array(matches.uids.prefix(MailConstants.pageSize))
                let fetched = await fetch(batch, folder: folder, uidValidity: matches.uidValidity,
                                          selection: selection, signIn: signIn, generation: generation)
                guard fetched == .shown else { return }
            }
        }
    }

    func clear() {
        supersede()
        query = ""
        results = nil
        usedLocalFallback = false
    }

    private func supersede() {
        generations.latest += 1
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

struct MailSearchFetchState {
    var unfetched: [String: MailListSearch.Matches] = [:]
    var gone: [String: Set<UInt32>] = [:]

    mutating func noteGone(_ requested: [UInt32], _ summaries: [MailSummary], folder: String) {
        let kept = Set(summaries.filter { !$0.isDeleted }.map(\.uid))
        gone[folder, default: []].formUnion(requested.filter { !kept.contains($0) })
    }

    func waiting(in matched: MailListSearch.Matches, folder: String, listed: Set<UInt32>) -> [UInt32] {
        let skipped = listed.union(gone[folder] ?? [])
        return matched.uids.filter { !skipped.contains($0) }
    }

    static func nextBatch(of waiting: [UInt32], listed: Set<UInt32>) -> [UInt32] {
        let oldestListed = listed.min() ?? .max
        let newerThanListed = waiting.prefix { $0 > oldestListed }.count
        let roomOnFirstPage = max(0, MailConstants.pageSize - listed.count)
        return Array(waiting.prefix(min(newerThanListed + roomOnFirstPage, MailConstants.pageSize)))
    }
}

private extension MailSummary {
    func matchesSearch(_ query: String) -> Bool {
        [subject, fromName, fromAddress].contains { $0?.localizedCaseInsensitiveContains(query) == true }
    }
}

enum MailCatchUpPass { case caughtUp, stopped, superseded }

@MainActor
final class MailSearchCatchUp {
    var isBehind = false
    private let delay: @Sendable () async -> Void
    private var task: Task<Void, Never>?

    init(delay: @escaping @Sendable () async -> Void) {
        self.delay = delay
    }

    func schedule(canRun: @escaping () -> Bool, run: @escaping () async -> MailCatchUpPass) {
        guard task == nil else { return }
        let delay = self.delay
        task = Task { [weak self] in
            await delay()
            passes: while let self, !Task.isCancelled, canRun(), self.isBehind {
                self.isBehind = false
                switch await run() {
                case .caughtUp: await delay()
                case .stopped:
                    self.isBehind = true
                    break passes
                case .superseded: return
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.task = nil
        }
    }

    func pauseUntilPageReopens() {
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
