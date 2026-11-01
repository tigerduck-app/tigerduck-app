#if os(iOS)
import Foundation
import Observation
import os

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

    func text(locale: Locale = .autoupdatingCurrent) -> String? {
        guard let total else { return nil }
        let format = IntegerFormatStyle<Int>.number.locale(locale)
        return done.formatted(format) + "/" + total.formatted(format)
    }
}

@MainActor
@Observable
final class MailIndexer {
    enum Request { case search, pull }

    private enum Outcome: String { case complete, failed, paused }

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

    private struct Plan {
        var folder: String
        var uidValidity: UInt32
        var missing: [UInt32]
    }

    private struct Coverage {
        var wipeCount: Int?
        var indexedFolders: Set<String> = []
        var lastPassCompleted = false
        var lastProgress: MailIndexProgress?
        var resets = 0
    }

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
    private(set) var isRunning = false
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

    private var notDueReason: String? {
        if task != nil { return "running" }
        if let reason = schedule.notDueReason(now: now, wipeCount: cache.wipeCount) { return reason }
        if isConstrained() { return "Low Data Mode" }
        return nil
    }

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

    var progress: MailIndexProgress? {
        coverage.wipeCount == cache.wipeCount ? coverage.lastProgress : nil
    }

    var isComplete: Bool {
        coverage.lastPassCompleted && coverage.wipeCount == cache.wipeCount
    }

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

    private func attempt<T>(_ step: () async throws -> T?) async throws -> T? {
        do {
            return try await step()
        } catch let error as MailClientError where MailErrorClass(error).endsTheRun {
            throw error
        } catch {
            return nil
        }
    }

    func update(folder: String, wipeCount: Int) async throws -> Bool {
        guard let plan = try await plan(folder: folder, wipeCount: wipeCount) else { return false }
        return try await fill(plan, wipeCount: wipeCount)
    }

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
