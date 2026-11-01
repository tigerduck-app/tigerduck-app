#if os(iOS)
import Foundation

struct MailFolderChoice: Equatable {
    var roles: [MailFolderRole: String] = [:]
    var others: [String] = []
    var selection: MailFolderSelection = .real(MailConstants.inbox)
    var wasChosen = false
    var unreadOnly = false

    var targets: [String] { selection.targets(roles: roles, others: others) }

    var showsAllMailChip: Bool {
        MailFolderSelection.allMail.targets(roles: roles, others: others).count > 1
    }
}

struct MailListStatus: Equatable {
    var loadState: MailListViewModel.LoadState = .idle
    var serverStatus: ServerStatus = .unknown
    var syncedAt: Date?
    var isRefreshing = false
    var isPaginating = false
    var sentCopyNotice: String?
}

struct MailListLoads {
    let account: AccountSession
    var loadingSelection: MailFolderSelection?
}

struct MailboxPages {
    private enum Edit {
        case seen(Bool)
        case removed
    }

    private struct MailKey: Hashable {
        var folder: String
        var uid: UInt32
    }

    private(set) var pages: [String: MailFolderPage] = [:]
    private(set) var rows: [MailListRow] = []
    var cachePainted: Set<String> = []
    private(set) var editToken = EditToken()
    private var edits: [MailKey: (token: EditToken, edit: Edit)] = [:]

    subscript(folder: String) -> MailFolderPage? {
        get { pages[folder] }
        set { pages[folder] = newValue }
    }

    mutating func removeAll() {
        pages = [:]
        rows = []
        cachePainted = []
        edits = [:]
    }

    mutating func drop(_ folder: String) {
        pages[folder] = nil
        edits = edits.filter { $0.key.folder != folder }
    }

    mutating func markSeen(folder: String, uid: UInt32, seen: Bool) {
        record(.seen(seen), folder: folder, uid: uid)
        if var page = pages[folder], let index = page.summaries.firstIndex(where: { $0.uid == uid }) {
            page.summaries[index].isSeen = seen
            pages[folder] = page
        }
    }

    mutating func remove(folder: String, uid: UInt32) {
        guard let page = pages[folder] else { return }
        record(.removed, folder: folder, uid: uid)
        pages[folder] = Self.removing(uid, from: page)
    }

    private mutating func record(_ edit: Edit, folder: String, uid: UInt32) {
        editToken.move()
        edits[MailKey(folder: folder, uid: uid)] = (editToken, edit)
    }

    func applyingEdits(to page: MailFolderPage, since token: EditToken) -> MailFolderPage {
        var page = page
        for (key, entry) in edits where key.folder == page.folder && entry.token > token {
            switch entry.edit {
            case .seen(let seen):
                if let index = page.summaries.firstIndex(where: { $0.uid == key.uid }) { page.summaries[index].isSeen = seen }
            case .removed:
                page = Self.removing(key.uid, from: page)
            }
        }
        return page
    }

    private static func removing(_ uid: UInt32, from page: MailFolderPage) -> MailFolderPage {
        var page = page
        let removed = page.summaries.contains { $0.uid == uid }
        page.summaries.removeAll { $0.uid == uid }
        if removed { page.messageCount = max(0, page.messageCount - 1) }
        return page
    }

    mutating func mergeFresh(_ fresh: MailFolderPage, folder: String, since token: EditToken) -> MailFolderPage {
        let previous = pages[folder]
        let hadPreviousPage = previous != nil
        let fromCache = cachePainted.remove(folder) != nil
        let existing = previous?.summaries ?? []
        let windowHidEverything = fresh.summaries.isEmpty && fresh.messageCount > 0
        let windowFloor = fresh.windowUIDs?.lowerBound ?? fresh.summaries.last?.uid
        let keptExisting: [MailSummary]
        if windowHidEverything {
            keptExisting = existing
        } else {
            keptExisting = windowFloor.map { floor in existing.filter { $0.uid < floor } } ?? []
        }
        let merged = (fresh.summaries + keptExisting).sorted { $0.uid > $1.uid }
        let oldestLoadedSequence: Int?
        if windowHidEverything, hadPreviousPage, !fromCache, !keptExisting.isEmpty {
            oldestLoadedSequence = previous?.oldestLoadedSequence
        } else if fresh.summaries.isEmpty {
            oldestLoadedSequence = fresh.oldestLoadedSequence
        } else if hadPreviousPage, !fromCache {
            oldestLoadedSequence = previous?.oldestLoadedSequence
        } else {
            oldestLoadedSequence = fresh.oldestLoadedSequence
        }
        let mergedPage = applyingEdits(to: MailFolderPage(
            folder: folder, uidValidity: fresh.uidValidity, messageCount: fresh.messageCount,
            summaries: merged, oldestLoadedSequence: oldestLoadedSequence, uidNext: fresh.uidNext,
            fetchedAt: fresh.fetchedAt
        ), since: token)
        pages[folder] = mergedPage
        return mergedPage
    }

    static func mergeOlder(_ older: MailFolderPage, into page: MailFolderPage) -> MailFolderPage {
        var merged = page
        if let window = older.windowUIDs ?? MailFolderPage.span(of: older.summaries.map(\.uid)) {
            let kept = page.summaries.filter { !window.contains($0.uid) }
            merged.summaries = (older.summaries + kept).sorted { $0.uid > $1.uid }
        }
        merged.oldestLoadedSequence = older.oldestLoadedSequence
        return merged
    }

    static func cachedCopy(of page: MailFolderPage) -> MailFolderPage {
        guard page.summaries.count > MailConstants.cachedPageRows else { return page }
        var copy = page
        copy.summaries = Array(page.summaries.prefix(MailConstants.cachedPageRows))
        let newestWindowStart = page.messageCount - MailConstants.pageSize + 1
        copy.oldestLoadedSequence = newestWindowStart > 1 ? newestWindowStart : nil
        return copy
    }

    mutating func rebuildRows(of folders: [String], newestFirst: Bool) {
        var collected: [MailListRow] = []
        for folder in folders {
            guard let page = pages[folder] else { continue }
            collected += page.summaries.map { MailListRow(folder: folder, summary: $0) }
        }
        rows = newestFirst ? collected.sorted(by: Self.newestFirst) : collected
    }

    func syncedAt(of folders: [String]) -> Date? {
        Self.syncedAt(of: folders.map { pages[$0] })
    }

    static func syncedAt(of pages: [MailFolderPage?]) -> Date? {
        var oldest: Date?
        for page in pages {
            guard let fetchedAt = page?.fetchedAt else { return nil }
            oldest = min(oldest ?? fetchedAt, fetchedAt)
        }
        return oldest
    }

    static func newestFirst(_ lhs: MailListRow, _ rhs: MailListRow) -> Bool {
        let left = lhs.summary.date ?? .distantPast
        let right = rhs.summary.date ?? .distantPast
        if left != right { return left > right }
        if lhs.folder != rhs.folder { return lhs.folder < rhs.folder }
        return lhs.uid > rhs.uid
    }
}
#endif
