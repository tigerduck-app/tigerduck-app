#if os(iOS)
import Foundation

/// The folders the server lists, by role and the rest, the one the list shows and its filter.
struct MailFolderChoice: Equatable {
    var roles: [MailFolderRole: String] = [:]
    var others: [String] = []
    var selection: MailFolderSelection = .real(MailConstants.inbox)
    /// The user picked `selection`, so the list no longer opens on All mail by itself.
    var wasChosen = false
    var unreadOnly = false

    var targets: [String] { selection.targets(roles: roles, others: others) }

    var showsAllMailChip: Bool {
        MailFolderSelection.allMail.targets(roles: roles, others: others).count > 1
    }
}

/// What the list shows about its loads beside the rows.
struct MailListStatus: Equatable {
    var loadState: MailListViewModel.LoadState = .idle
    var serverStatus: ServerStatus = .unknown
    var syncedAt: Date?
    var isRefreshing = false
    var isPaginating = false
    var sentCopyNotice: String?
}

/// Which loads still apply: a sign-out or a server change moves `accountEpoch`, and
/// `loadingSelection` keeps a second load of the same selection from starting.
struct MailListLoads {
    var accountEpoch = 0
    var loadingSelection: MailFolderSelection?
}

/// The mailbox the list shows: each folder's loaded page, and the read flags and removals the user
/// made. A page fetched before such an edit does not undo it: each edit moves `editToken`, and a
/// page merged in gets the edits made since the token its fetch started with.
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
    /// The rows of the folders the list shows, kept by `rebuildRows`.
    private(set) var rows: [MailListRow] = []
    /// Folders whose page came from the cache and has not been refreshed yet.
    var cachePainted: Set<String> = []
    private(set) var editToken = EditToken()
    private var edits: [MailKey: (token: EditToken, edit: Edit)] = [:]

    subscript(folder: String) -> MailFolderPage? {
        get { pages[folder] }
        set { pages[folder] = newValue }
    }

    /// Also forgets the edits: a load started after this has nothing older to undo.
    mutating func removeAll() {
        pages = [:]
        rows = []
        cachePainted = []
        edits = [:]
    }

    /// Forgets `folder`'s page and edits, as when the folder was recreated and its UIDs name other mail.
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

    /// `page` with the edits of its folder made after `token`.
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

    /// Merges a fresh newest page into what is loaded: new mail is added, and mail the user
    /// paginated to beyond this page is kept.
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

    /// The part of a page the cache keeps: its newest rows, with the cursor of the newest window.
    static func cachedCopy(of page: MailFolderPage) -> MailFolderPage {
        guard page.summaries.count > MailConstants.cachedPageRows else { return page }
        var copy = page
        copy.summaries = Array(page.summaries.prefix(MailConstants.cachedPageRows))
        let newestWindowStart = page.messageCount - MailConstants.pageSize + 1
        copy.oldestLoadedSequence = newestWindowStart > 1 ? newestWindowStart : nil
        return copy
    }

    /// All mail interleaves its folders newest first; one folder keeps its page's order.
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
