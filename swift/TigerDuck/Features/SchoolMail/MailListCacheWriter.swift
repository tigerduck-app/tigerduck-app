#if os(iOS)
import Foundation

@MainActor
final class MailListCacheWriter {
    let cache: MailCache
    private var pending: Task<Void, Never>?

    init(cache: MailCache) {
        self.cache = cache
    }

    func save(_ page: MailFolderPage) async {
        let cache = self.cache
        let stored = MailboxPages.cachedCopy(of: page)
        await chain { cache.savePage(stored, wipeCount: $0) }.value
    }

    func persist(_ page: MailFolderPage) {
        let cache = self.cache
        let stored = MailboxPages.cachedCopy(of: page)
        chain { cache.savePage(stored, wipeCount: $0) }
    }

    func dropFolder(_ folder: String) async {
        let cache = self.cache
        await chain { _ in cache.dropFolder(folder) }.value
    }

    func cachedPage(folder: String) async -> MailFolderPage? {
        let cache = self.cache
        return await Task.detached { cache.loadPage(folder: folder) }.value
    }

    func waitForWrites() async {
        await pending?.value
    }

    @discardableResult
    func chain(_ operation: @escaping @Sendable (_ wipeCount: Int) -> Void) -> Task<Void, Never> {
        let previous = pending
        let wipeCount = cache.wipeCount
        let task = Task.detached {
            _ = await previous?.value
            operation(wipeCount)
        }
        pending = task
        return task
    }
}
#endif
