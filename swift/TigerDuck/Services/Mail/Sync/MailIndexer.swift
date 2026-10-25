#if os(iOS)
import Foundation

/// Downloads every folder's mail into `MailSearchIndex` while the mail page is on screen, newest
/// first and `MailConstants.indexBatchSize` mails per command. A pass that got through holds off
/// the next for `MailConstants.indexResyncInterval`, unless mail arrived since; one that failed
/// waits longer before each retry, and Low Data Mode pauses it.
/// See docs/decisions/0027-mail-local-search-index.md.
@MainActor
final class MailIndexer {
    private enum Outcome { case complete, failed, paused }

    private struct MailKey: Hashable {
        var folder: String
        var uidValidity: UInt32
        var uid: UInt32
    }

    private static let failuresBeforeSkipping = 2

    private let session: MailPageSession
    private let cache: MailCache
    private let startDelay: @Sendable () async -> Void
    private let now: () -> Date
    private let isConstrained: () -> Bool
    private var task: Task<Void, Never>?
    private var stopping: Task<Void, Never>?
    private var completed: (at: Date, wipeCount: Int)?
    private var retryAt: Date?
    private var failedPasses = 0
    private var arrivals = 0
    /// Mails a failed batch held: fetched one at a time from then on, and skipped after failing
    /// alone `failuresBeforeSkipping` times. Kept until the account changes or the app quits.
    private var strikes: [MailKey: Int] = [:]

    init(
        session: MailPageSession,
        cache: MailCache,
        startDelay: @escaping @Sendable () async -> Void,
        now: @escaping () -> Date = Date.init,
        isConstrained: (() -> Bool)? = nil
    ) {
        self.session = session
        self.cache = cache
        self.startDelay = startDelay
        self.now = now
        self.isConstrained = isConstrained ?? { NetworkMonitor.shared.isConstrained }
    }

    func startIfDue(folders: [String]) {
        guard task == nil, !isFresh, retryAt.map({ now() >= $0 }) ?? true, !isConstrained() else { return }
        let arrivals = self.arrivals
        let wipeCount = cache.wipeCount
        let delay = startDelay
        let previous = stopping
        task = Task { [weak self] in
            // A pass stopped a moment ago may still be filing its last batch.
            await previous?.value
            await delay()
            guard let self, !Task.isCancelled else { return }
            let outcome = await self.pass(folders: folders, wipeCount: wipeCount)
            guard !Task.isCancelled else { return }
            self.task = nil
            self.finish(outcome, arrivals: arrivals, wipeCount: wipeCount, folders: folders)
        }
    }

    /// Stops after the batch in flight, which SwiftMail cannot abort.
    func stop() {
        task?.cancel()
        if let task { stopping = task }
        task = nil
    }

    func reset() {
        stop()
        completed = nil
        retryAt = nil
        failedPasses = 0
        strikes = [:]
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

    private func finish(_ outcome: Outcome, arrivals: Int, wipeCount: Int, folders: [String]) {
        switch outcome {
        case .paused:
            return
        case .failed:
            failedPasses += 1
            let delay = MailConstants.indexRetryDelay * Double(1 << min(failedPasses - 1, 4))
            retryAt = now().addingTimeInterval(min(delay, MailConstants.indexResyncInterval))
        case .complete:
            failedPasses = 0
            retryAt = nil
            if self.arrivals == arrivals {
                completed = (now(), wipeCount)
            } else {
                startIfDue(folders: folders)
            }
        }
    }

    /// A lost connection, a busy server or a rejected password ends the pass rather than trying
    /// each folder again: NTUST counts failed logins towards a lockout.
    private func pass(folders: [String], wipeCount: Int) async -> Outcome {
        var failed = false
        for folder in folders {
            guard !Task.isCancelled, !isConstrained() else { return .paused }
            do {
                if !(try await update(folder: folder, wipeCount: wipeCount)) { failed = true }
            } catch let error as MailClientError where MailChecker.endsPrefetch(error) {
                return isConstrained() ? .paused : .failed
            } catch {
                failed = true
            }
        }
        if isConstrained() { return .paused }
        return failed ? .failed : .complete
    }

    /// Brings `folder`'s index to the server's mail; false when it stopped before the end or a
    /// batch failed.
    func update(folder: String, wipeCount: Int) async throws -> Bool {
        let index = cache.searchIndex
        let listed = try await session.use { client in try await client.undeletedUIDs(folder: folder) }
        let validity = listed.uidValidity
        let onServer = Set(listed.uids)
        guard !Task.isCancelled, let held = await Task.detached(operation: {
            index.prepare(folder: folder, uidValidity: validity, onServer: onServer, wipeCount: wipeCount)
        }).value else { return false }
        let missing = onServer.subtracting(held).filter {
            (strikes[MailKey(folder: folder, uidValidity: validity, uid: $0)] ?? 0) < Self.failuresBeforeSkipping
        }
        var complete = true
        for batch in batches(of: missing.sorted(by: >), folder: folder, uidValidity: validity) {
            guard !Task.isCancelled, !isConstrained() else { return false }
            let texts: [UInt32: String]
            do {
                texts = try await session.use { client in
                    try await client.searchTexts(folder: folder, uids: batch, expectedUIDValidity: validity)
                }
            } catch let error as MailClientError where Self.blamesTheMail(error) {
                // A stop, as at sign-out, can be what failed it.
                guard !Task.isCancelled else { return false }
                strike(batch, folder: folder, uidValidity: validity)
                if MailChecker.endsPrefetch(error) { throw error }
                complete = false
                continue
            }
            let added = await Task.detached {
                index.add(texts, folder: folder, uidValidity: validity, wipeCount: wipeCount)
            }.value
            guard added else { return false }
        }
        return complete
    }

    /// Newest first; a mail with a strike goes alone, so the one that fails is found.
    private func batches(of missing: [UInt32], folder: String, uidValidity: UInt32) -> [[UInt32]] {
        var batches: [[UInt32]] = []
        var current: [UInt32] = []
        for uid in missing {
            if strikes[MailKey(folder: folder, uidValidity: uidValidity, uid: uid)] != nil {
                if !current.isEmpty { batches.append(current) }
                batches.append([uid])
                current = []
                continue
            }
            current.append(uid)
            if current.count == MailConstants.indexBatchSize {
                batches.append(current)
                current = []
            }
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    private func strike(_ batch: [UInt32], folder: String, uidValidity: UInt32) {
        for uid in batch {
            let key = MailKey(folder: folder, uidValidity: uidValidity, uid: uid)
            strikes[key] = (strikes[key] ?? 0) + (batch.count == 1 ? 1 : 0)
        }
    }

    /// A timeout or an answer that will not parse can be one mail's doing; a rejected password,
    /// a busy server, a certificate or a recreated folder is not.
    nonisolated static func blamesTheMail(_ error: MailClientError) -> Bool {
        switch error {
        case .unreachable, .protocolError: true
        case .authenticationFailed, .certificateRejected, .serverBusy, .searchUnsupported, .folderChanged,
             .sendUnconfirmed: false
        }
    }
}
#endif
