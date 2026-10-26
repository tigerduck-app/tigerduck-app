#if os(iOS)
import Foundation
import Observation
import os

/// How far a pass of `MailIndexer` has come: `done` of the `total` mails the index lacked, or
/// `counting` while the pass still lists every folder for that total.
nonisolated struct MailIndexProgress: Equatable, Sendable {
    private(set) var done = 0
    let total: Int?

    static let counting = MailIndexProgress(total: nil)

    init(total: Int?) {
        self.total = total
    }

    mutating func advance(by count: Int) {
        done += count
    }

    /// "120/3,456", with `locale`'s digit grouping; nil while there is no total yet.
    func text(locale: Locale = .autoupdatingCurrent) -> String? {
        guard let total else { return nil }
        let format = IntegerFormatStyle<Int>.number.locale(locale)
        return done.formatted(format) + "/" + total.formatted(format)
    }
}

/// Downloads every folder's mail into `MailSearchIndex` while the mail page is on screen, newest
/// first and `MailConstants.indexBatchSize` mails per command. A pass that got through holds off
/// the next for `MailConstants.indexResyncInterval`, unless mail arrived since; one that failed
/// waits longer before each retry, unless the cache was cleared since, and Low Data Mode pauses it.
/// See docs/decisions/0027-mail-local-search-index.md.
@MainActor
@Observable
final class MailIndexer {
    private enum Outcome: String { case complete, failed, paused }

    /// A pass's counts for the log, which never names a folder or a mail.
    private struct Tally {
        var listed = 0
        var failed = 0
        var toFetch = 0
        var done = 0
    }

    /// What a folder's index lacks, newest first.
    private struct Plan {
        var folder: String
        var uidValidity: UInt32
        var missing: [UInt32]
    }

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
    /// Mails of a batch whose answer would not parse: fetched one at a time from then on, and
    /// skipped after failing alone `failuresBeforeSkipping` times. Kept until the account changes,
    /// the cache is cleared or the app quits.
    private var strikes: [MailKey: Int] = [:]
    /// The cache's `wipeCount` when the last pass began, which its retry and strikes belong to.
    private var passWipeCount: Int?
    private(set) var progress: MailIndexProgress?

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
        // A cleared cache emptied the index: a pass under way can no longer write to it, and the
        // failures before it no longer hold the next pass off.
        if let passWipeCount, passWipeCount != cache.wipeCount { reset() }
        if let reason = notDueReason {
            AppLogger.mail.info("Index pass not started: \(reason, privacy: .public)")
            return
        }
        let arrivals = self.arrivals
        let wipeCount = cache.wipeCount
        passWipeCount = wipeCount
        let delay = startDelay
        let previous = stopping
        task = Task { [weak self] in
            // A pass stopped a moment ago may still be filing its last batch.
            await previous?.value
            await delay()
            guard let self, !Task.isCancelled else { return }
            AppLogger.mail.info("Index pass started: folders=\(folders.count, privacy: .public)")
            var tally = Tally()
            let outcome = await self.pass(folders: folders, wipeCount: wipeCount, tally: &tally)
            guard !Task.isCancelled else {
                Self.logEnd(.paused, tally)
                return
            }
            self.task = nil
            self.finish(outcome, tally: tally, arrivals: arrivals, wipeCount: wipeCount, folders: folders)
        }
    }

    /// Why `startIfDue` starts no pass now, as a fixed label for the log; nil when one is due.
    private var notDueReason: String? {
        if task != nil { return "running" }
        if isFresh { return "fresh" }
        if let retryAt, now() < retryAt {
            return "waiting for retry in \(Int(retryAt.timeIntervalSince(now()).rounded(.up)))s"
        }
        if isConstrained() { return "Low Data Mode" }
        return nil
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

    private func finish(_ outcome: Outcome, tally: Tally, arrivals: Int, wipeCount: Int, folders: [String]) {
        switch outcome {
        case .paused:
            Self.logEnd(outcome, tally)
        case .failed:
            failedPasses += 1
            let delay = MailConstants.indexRetryDelay * Double(1 << min(failedPasses - 1, 4))
            let retryIn = min(delay, MailConstants.indexResyncInterval)
            retryAt = now().addingTimeInterval(retryIn)
            Self.logEnd(outcome, tally, retryIn: retryIn)
        case .complete:
            Self.logEnd(outcome, tally)
            failedPasses = 0
            retryAt = nil
            if self.arrivals == arrivals {
                completed = (now(), wipeCount)
            } else {
                startIfDue(folders: folders)
            }
        }
    }

    /// Lists every folder before it downloads any, so the progress has one total from the start.
    /// A lost connection, a busy server or a rejected password ends the pass rather than trying
    /// each folder again: NTUST counts failed logins towards a lockout.
    private func pass(folders: [String], wipeCount: Int, tally: inout Tally) async -> Outcome {
        progress = .counting
        defer {
            tally.done = progress?.done ?? 0
            progress = nil
        }
        do {
            var plans: [Plan] = []
            for folder in folders {
                guard !Task.isCancelled, !isConstrained() else { return .paused }
                if let plan = try await attempt({ try await self.plan(folder: folder, wipeCount: wipeCount) }) {
                    plans.append(plan)
                    tally.listed += 1
                } else {
                    tally.failed += 1
                }
            }
            let total = plans.reduce(0) { $0 + $1.missing.count }
            tally.toFetch = total
            // An index that is already current shows nothing rather than spinning at 0/0.
            progress = total > 0 ? MailIndexProgress(total: total) : nil
            for plan in plans {
                guard !Task.isCancelled, !isConstrained() else { return .paused }
                let filled = try await attempt {
                    try await self.fill(plan, wipeCount: wipeCount) { self.progress?.advance(by: $0) }
                }
                if filled != true { tally.failed += 1 }
            }
        } catch {
            tally.failed += 1
            return isConstrained() ? .paused : .failed
        }
        if isConstrained() { return .paused }
        return tally.failed > 0 ? .failed : .complete
    }

    private static func logEnd(_ outcome: Outcome, _ tally: Tally, retryIn: TimeInterval? = nil) {
        let retry = retryIn.map { "\(Int($0))s" } ?? "none"
        AppLogger.mail.info("""
            Index pass \(outcome.rawValue, privacy: .public): listed=\(tally.listed, privacy: .public) \
            failed=\(tally.failed, privacy: .public) toFetch=\(tally.toFetch, privacy: .public) \
            done=\(tally.done, privacy: .public) retryIn=\(retry, privacy: .public)
            """)
    }

    /// One folder's step; nil when it failed. Throws only an error that ends the pass.
    private func attempt<T>(_ step: () async throws -> T?) async throws -> T? {
        do {
            return try await step()
        } catch let error as MailClientError where MailChecker.endsPrefetch(error) {
            throw error
        } catch {
            return nil
        }
    }

    /// Brings `folder`'s index to the server's mail; false when it stopped before the end or a
    /// batch failed.
    func update(folder: String, wipeCount: Int) async throws -> Bool {
        guard let plan = try await plan(folder: folder, wipeCount: wipeCount) else { return false }
        return try await fill(plan, wipeCount: wipeCount)
    }

    /// Drops the mail the server no longer has from `folder`'s index; nil when it stopped.
    private func plan(folder: String, wipeCount: Int) async throws -> Plan? {
        let index = cache.searchIndex
        let listed = try await session.use { client in try await client.undeletedUIDs(folder: folder) }
        let validity = listed.uidValidity
        let onServer = Set(listed.uids)
        guard !Task.isCancelled, let held = await Task.detached(operation: {
            index.prepare(folder: folder, uidValidity: validity, onServer: onServer, wipeCount: wipeCount)
        }).value else { return nil }
        let missing = onServer.subtracting(held).filter {
            (strikes[MailKey(folder: folder, uidValidity: validity, uid: $0)] ?? 0) < Self.failuresBeforeSkipping
        }
        return Plan(folder: folder, uidValidity: validity, missing: missing.sorted(by: >))
    }

    /// Tells `onBatch` how many mails each batch dealt with, a failed one's too.
    private func fill(_ plan: Plan, wipeCount: Int, onBatch: (Int) -> Void = { _ in }) async throws -> Bool {
        let index = cache.searchIndex
        let folder = plan.folder
        let validity = plan.uidValidity
        var complete = true
        for batch in batches(of: plan.missing, folder: folder, uidValidity: validity) {
            guard !Task.isCancelled, !isConstrained() else { return false }
            do {
                let texts = try await session.use { client in
                    try await client.searchTexts(folder: folder, uids: batch, expectedUIDValidity: validity)
                }
                let added = await Task.detached {
                    index.add(texts, folder: folder, uidValidity: validity, wipeCount: wipeCount)
                }.value
                guard added else { return false }
            } catch let error as MailClientError where Self.blamesTheMail(error) {
                // A stop, as at sign-out, can be what failed it.
                guard !Task.isCancelled else { return false }
                strike(batch, folder: folder, uidValidity: validity)
                complete = false
            }
            onBatch(batch.count)
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

    /// An answer that will not parse can be one mail's doing; a lost connection, a rejected
    /// password, a busy server, a certificate or a recreated folder is not.
    nonisolated static func blamesTheMail(_ error: MailClientError) -> Bool {
        switch error {
        case .protocolError: true
        case .unreachable, .authenticationFailed, .certificateRejected, .serverBusy, .searchUnsupported,
             .folderChanged, .sendUnconfirmed: false
        }
    }
}
#endif
