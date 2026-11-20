#if os(iOS)
import Foundation

@MainActor
final class MailListCacheWriter {
    let cache: MailCache
    private var pending: Task<Void, Never>?

    init(cache: MailCache) {
        self.cache = cache
    }

    @discardableResult
    func save(_ page: MailFolderPage) -> Task<Void, Never> {
        let cache = self.cache
        let stored = MailboxPages.cachedCopy(of: page)
        return enqueue { cache.savePage(stored, unlessWipedSince: $0) }
    }

    func dropFolder(_ folder: String) async {
        let cache = self.cache
        await enqueue { _ in cache.dropFolder(folder) }.value
    }

    func cachedPage(folder: String) async -> MailFolderPage? {
        let cache = self.cache
        return await Task.detached { cache.loadPage(folder: folder) }.value
    }

    func waitForWrites() async {
        await pending?.value
    }

    @discardableResult
    func enqueue(_ write: @escaping @Sendable (_ wipeCountWhenAsked: Int) -> Void) -> Task<Void, Never> {
        let previous = pending
        let wipeCount = cache.wipeCount
        let task = Task.detached {
            _ = await previous?.value
            write(wipeCount)
        }
        pending = task
        return task
    }
}
#endif
