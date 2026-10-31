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
/// A pass the user asks for skips some of these waits (`Request`).
/// See docs/decisions/0027-mail-local-search-index.md.
@MainActor
@Observable
final class MailIndexer {
    /// A pass the user asked for: a search skips the wait after a pass that got through, and a
    /// pull also the wait after one that failed, which a folder failing every pass would otherwise
    /// turn into a full listing per search.
    enum Request { case search, pull }

    private enum Outcome: String { case complete, failed, paused }

    /// A pass's counts for the log, which never names a folder or a mail.
    private struct Tally {
        var listed = 0
        var failed = 0
        var toFetch = 0
        var done = 0

        func logEnd(_ outcome: Outcome, retryIn: TimeInterval? = nil) {
            let retry = retryIn.map { "\(Int($0))s" } ?? "none"
            AppLogger.mail.info("""
                Index pass \(outcome.rawValue, privacy: .public): listed=\(listed, privacy: .public) \
                failed=\(failed, privacy: .public) toFetch=\(toFetch, privacy: .public) \
                done=\(done, privacy: .public) retryIn=\(retry, privacy: .public)
                """)
        }
    }

    /// What a folder's index lacks, newest first.
    private struct Plan {
        var folder: String
        var uidValidity: UInt32
        var missing: [UInt32]
    }

    /// What the passes since the last wipe or account change found.
    private struct Coverage {
        /// The cache's `wipeCount` when the last pass began, which its retry and strikes belong to.
        var wipeCount: Int?
        /// The folders the index held all the mail of when a pass last listed or filled them.
        var indexedFolders: Set<String> = []
        var lastPassCompleted = false
        var lastProgress: MailIndexProgress?
        /// Moves on each `reset()`, so a pass it stopped writes nothing after it.
        var resets = 0
    }

    /// The waits and the network condition a pass is paced by.
    private struct Pacing {
        let startDelay: @Sendable () async -> Void
        let now: () -> Date
        let isConstrained: () -> Bool
    }

    private let session: MailPageSession
    private let cache: MailCache
    private let pacing: Pacing
    private var task: Task<Void, Never>?
    private var stopping: Task<Void, Never>?
    private var schedule = MailIndexSchedule()
    private var strikes = MailIndexStrikes()
    private var coverage = Coverage()
    /// Whether a pass is listing or downloading.
    private(set) var isRunning = false
    /// Told the folder each time a batch of its mail joins the index.
    @ObservationIgnored var onFill: ((String) -> Void)?

    init(
        session: MailPageSession,
        cache: MailCache,
        startDelay: @escaping @Sendable () async -> Void,
        now: @escaping () -> Date = Date.init,
        isConstrained: (() -> Bool)? = nil
    ) {
        self.session = session
        self.cache = cache
        pacing = Pacing(startDelay: startDelay, now: now,
                        isConstrained: isConstrained ?? { NetworkMonitor.shared.isConstrained })
    }

    private var now: Date { pacing.now() }
    private func isConstrained() -> Bool { pacing.isConstrained() }

    func startIfDue(folders: [String], for request: Request? = nil) {
        // A cleared cache emptied the index: a pass under way can no longer write to it, and the
        // failures before it no longer hold the next pass off.
        if let passWipeCount = coverage.wipeCount, passWipeCount != cache.wipeCount { reset() }
        if request != nil { schedule.skipFreshness() }
        if request == .pull { schedule.skipRetryWait() }
        if let reason = notDueReason {
            AppLogger.mail.info("Index pass not started: \(reason, privacy: .public)")
            return
        }
        let arrivals = schedule.arrivals
        let wipeCount = cache.wipeCount
        coverage.wipeCount = wipeCount
        let delay = pacing.startDelay
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
                self.coverage.lastPassCompleted = false
                tally.logEnd(.paused)
                return
            }
            self.task = nil
            self.finish(outcome, tally: tally, arrivals: arrivals, wipeCount: wipeCount, folders: folders)
        }
    }

    /// Why `startIfDue` starts no pass now, as a fixed label for the log; nil when one is due.
    private var notDueReason: String? {
        if task != nil { return "running" }
        if let reason = schedule.notDueReason(now: now, wipeCount: cache.wipeCount) { return reason }
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
        schedule.reset()
        strikes = MailIndexStrikes()
        coverage = Coverage(wipeCount: coverage.wipeCount, resets: coverage.resets + 1)
    }

    /// The last pass's count, kept after it ends; nil before a pass since the last wipe.
    var progress: MailIndexProgress? {
        coverage.wipeCount == cache.wipeCount ? coverage.lastProgress : nil
    }

    /// Whether a pass got through since the last wipe or account change, and none failed or
    /// paused after it.
    var isComplete: Bool {
        coverage.lastPassCompleted && coverage.wipeCount == cache.wipeCount
    }

    /// Whether the index held all of `folder`'s mail when a pass last reached it.
    func isIndexed(_ folder: String) -> Bool {
        coverage.wipeCount == cache.wipeCount && coverage.indexedFolders.contains(folder)
    }

    func noteNewMail() {
        schedule.noteNewMail()
    }

    func waitForPass() async {
        await task?.value
    }

    private func finish(_ outcome: Outcome, tally: Tally, arrivals: Int, wipeCount: Int, folders: [String]) {
        coverage.lastPassCompleted = outcome == .complete
        switch outcome {
        case .paused:
            tally.logEnd(outcome)
        case .failed:
            tally.logEnd(outcome, retryIn: schedule.passFailed(now: now))
        case .complete:
            tally.logEnd(outcome)
            if !schedule.passCompleted(now: now, wipeCount: wipeCount, arrivalsAtStart: arrivals) {
                startIfDue(folders: folders)
            }
        }
    }

    /// Lists every folder before it downloads any, so the progress has one total from the start.
    /// A lost connection, a busy server or a rejected password ends the pass rather than trying
    /// each folder again: NTUST counts failed logins towards a lockout.
    private func pass(folders: [String], wipeCount: Int, tally: inout Tally) async -> Outcome {
        let resets = coverage.resets
        isRunning = true
        coverage.lastProgress = .counting
        defer {
            tally.done = coverage.lastProgress?.done ?? 0
            isRunning = false
        }
        do {
            var plans: [Plan] = []
            for folder in folders {
                guard !Task.isCancelled, !isConstrained() else { return .paused }
                let plan = try await attempt { try await self.plan(folder: folder, wipeCount: wipeCount) }
                guard resets == coverage.resets else { return .paused }
                if let plan {
                    plans.append(plan)
                    tally.listed += 1
                    if plan.missing.isEmpty { coverage.indexedFolders.insert(folder) } else { coverage.indexedFolders.remove(folder) }
                } else {
                    coverage.indexedFolders.remove(folder)
                    tally.failed += 1
                }
            }
            let total = plans.reduce(0) { $0 + $1.missing.count }
            tally.toFetch = total
            coverage.lastProgress = MailIndexProgress(total: total)
            for plan in plans {
                guard !Task.isCancelled, !isConstrained() else { return .paused }
                let filled = try await attempt {
                    try await self.fill(plan, wipeCount: wipeCount) { count in
                        if resets == self.coverage.resets { self.coverage.lastProgress?.advance(by: count) }
                    }
                }
                guard resets == coverage.resets else { return .paused }
                if filled == true {
                    coverage.indexedFolders.insert(plan.folder)
                } else {
                    tally.failed += 1
                }
            }
        } catch {
            tally.failed += 1
            return isConstrained() ? .paused : .failed
        }
        if isConstrained() { return .paused }
        return tally.failed > 0 ? .failed : .complete
    }

    /// One folder's step; nil when it failed. Throws only an error that ends the pass.
    private func attempt<T>(_ step: () async throws -> T?) async throws -> T? {
        do {
            return try await step()
        } catch let error as MailClientError where MailErrorClass(error).endsTheRun {
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
        let missing = onServer.subtracting(held).filter { !strikes.skips($0, folder: folder, uidValidity: validity) }
        return Plan(folder: folder, uidValidity: validity, missing: missing.sorted(by: >))
    }

    /// Tells `onBatch` how many mails each batch dealt with, a failed one's too.
    private func fill(_ plan: Plan, wipeCount: Int, onBatch: (Int) -> Void = { _ in }) async throws -> Bool {
        let index = cache.searchIndex
        let folder = plan.folder
        let validity = plan.uidValidity
        var complete = true
        for batch in strikes.batches(of: plan.missing, folder: folder, uidValidity: validity) {
            guard !Task.isCancelled, !isConstrained() else { return false }
            do {
                let texts = try await session.use { client in
                    try await client.searchTexts(folder: folder, uids: batch, expectedUIDValidity: validity)
                }
                let added = await Task.detached {
                    index.add(texts, folder: folder, uidValidity: validity, wipeCount: wipeCount)
                }.value
                guard added else { return false }
                onFill?(folder)
            } catch let error as MailClientError where MailErrorClass(error).blamesTheMail {
                // A stop, as at sign-out, can be what failed it.
                guard !Task.isCancelled else { return false }
                strikes.strike(batch, folder: folder, uidValidity: validity)
                complete = false
            }
            onBatch(batch.count)
        }
        return complete
    }
}
#endif
