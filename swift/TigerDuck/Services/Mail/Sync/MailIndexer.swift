#if os(iOS)
import Foundation

/// Downloads every folder's mail into `MailSearchIndex` while the mail page is on screen, newest
/// first and `MailConstants.indexBatchSize` mails per command. A pass that got through holds off
/// the next for `MailConstants.indexResyncInterval`, unless mail arrived since.
/// See docs/decisions/0027-mail-local-search-index.md.
@MainActor
final class MailIndexer {
    private let session: MailPageSession
    private let cache: MailCache
    private let startDelay: @Sendable () async -> Void
    private let now: () -> Date
    private var task: Task<Void, Never>?
    private var completed: (at: Date, wipeCount: Int)?
    private var arrivals = 0

    init(
        session: MailPageSession,
        cache: MailCache,
        startDelay: @escaping @Sendable () async -> Void,
        now: @escaping () -> Date = Date.init
    ) {
        self.session = session
        self.cache = cache
        self.startDelay = startDelay
        self.now = now
    }

    func startIfDue(folders: [String]) {
        guard task == nil, !isFresh else { return }
        let arrivals = self.arrivals
        let wipeCount = cache.wipeCount
        let delay = startDelay
        task = Task { [weak self] in
            await delay()
            guard let self, !Task.isCancelled else { return }
            let complete = await self.pass(folders: folders, wipeCount: wipeCount)
            guard !Task.isCancelled else { return }
            self.task = nil
            guard complete else { return }
            if self.arrivals == arrivals {
                self.completed = (self.now(), wipeCount)
            } else {
                self.startIfDue(folders: folders)
            }
        }
    }

    /// Stops after the batch in flight, which SwiftMail cannot abort.
    func stop() {
        task?.cancel()
        task = nil
    }

    func reset() {
        stop()
        completed = nil
    }

    func noteNewMail() {
        arrivals += 1
        completed = nil
    }

    func waitForPass() async {
        await task?.value
    }

    private var isFresh: Bool {
        guard let completed, completed.wipeCount == cache.wipeCount else { return false }
        return now().timeIntervalSince(completed.at) < MailConstants.indexResyncInterval
    }

    /// A lost connection, a busy server or a rejected password ends the pass rather than trying
    /// each folder again: NTUST counts failed logins towards a lockout.
    private func pass(folders: [String], wipeCount: Int) async -> Bool {
        var complete = true
        for folder in folders {
            guard !Task.isCancelled else { return false }
            do {
                complete = try await update(folder: folder, wipeCount: wipeCount) && complete
            } catch let error as MailClientError where MailChecker.endsPrefetch(error) {
                return false
            } catch {
                complete = false
            }
        }
        return complete
    }

    /// Brings `folder`'s index to the server's mail; false when it stopped before the end.
    func update(folder: String, wipeCount: Int) async throws -> Bool {
        let index = cache.searchIndex
        let listed = try await session.use { client in try await client.undeletedUIDs(folder: folder) }
        let validity = listed.uidValidity
        let onServer = Set(listed.uids)
        guard !Task.isCancelled, let held = await Task.detached(operation: {
            index.prepare(folder: folder, uidValidity: validity, onServer: onServer, wipeCount: wipeCount)
        }).value else { return false }
        let missing = onServer.subtracting(held).sorted(by: >)
        for start in stride(from: 0, to: missing.count, by: MailConstants.indexBatchSize) {
            guard !Task.isCancelled else { return false }
            let batch = Array(missing[start..<min(start + MailConstants.indexBatchSize, missing.count)])
            let texts = try await session.use { client in
                try await client.searchTexts(folder: folder, uids: batch, expectedUIDValidity: validity)
            }
            let added = await Task.detached {
                index.add(texts, folder: folder, uidValidity: validity, wipeCount: wipeCount)
            }.value
            guard added else { return false }
        }
        return true
    }
}
#endif
