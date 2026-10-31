import Foundation
import os

actor SyncOutbox {
    static let maxAttempts = 5

    private let files: OutboxFiles
    private var entries: [OutboxEntry] = []
    private var parked: [OutboxEntry] = []
    private var generation = 0
    /// False while a queue file exists but could not be read, as at a launch behind the lock
    /// screen (`completeFileProtectionUnlessOpen`). Until it is read, or `loadOrGiveUp` gives up
    /// on it, nothing is written over the files, and what was queued meanwhile joins what they hold.
    private var isLoaded: Bool
    private var unreadableLoads = 0
    private var cutoffs: [String: Date] = [:]
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "CloudSync.Outbox")

    init(
        directory: URL = OutboxFiles.defaultDirectory(),
        read: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) {
        files = OutboxFiles(directory: directory, read: read)
        let loaded = files.load()
        self.entries = loaded?.queued ?? []
        self.parked = loaded?.parked ?? []
        self.isLoaded = loaded != nil
    }

    func enqueue(_ op: SyncOp) {
        loadIfNeeded()
        guard !Self.isCutOff(op, by: cutoffs) else { return }
        let key = op.dedupKey
        entries.removeAll { $0.op.dedupKey == key }
        parked.removeAll { $0.op.dedupKey == key }
        entries.append(OutboxEntry(id: UUID(), op: op, attempts: 0))
        persist()
    }

    func pendingCount() -> Int {
        loadIfNeeded()
        return entries.count
    }

    static let unreadableLoadLimit = 3

    func loadOrGiveUp(protectedDataAvailable: Bool) {
        guard !isLoaded else { return }
        if let onDisk = files.load() {
            adopt(queued: onDisk.queued, parked: onDisk.parked)
            return
        }
        guard protectedDataAvailable else { return }
        unreadableLoads += 1
        guard unreadableLoads >= Self.unreadableLoadLimit else { return }
        logger.error("Outbox: queue files unreadable while protected data is available, giving up on them")
        let readable = files.loadReadable()
        adopt(queued: readable.queued, parked: readable.parked)
    }

    func holdsEntries() -> Bool {
        loadIfNeeded()
        return !entries.isEmpty || !parked.isEmpty
    }

    func snapshot() -> [OutboxEntry] {
        loadIfNeeded()
        return entries
    }

    func parkedSnapshot() -> [OutboxEntry] {
        loadIfNeeded()
        return parked
    }

    func clearAll() {
        entries = []
        parked = []
        cutoffs = [:]
        isLoaded = true
        generation += 1
        persist()
    }

    @discardableResult
    func discard(where isDropped: @Sendable (SyncOp) -> Bool) -> [SyncOp] {
        loadIfNeeded()
        let dropped = (entries + parked).map(\.op).filter(isDropped)
        entries.removeAll { isDropped($0.op) }
        parked.removeAll { isDropped($0.op) }
        persist()
        return dropped
    }

    /// Discards the ops made before the cutoff of a scope they fall under, and refuses such an op
    /// still on its way in, as one whose enqueue task had not reached the outbox yet. One cutoff
    /// is kept per scope, and none later than now, so it never refuses an edit made after this.
    @discardableResult
    func discard(madeBefore scopeCutoffs: [String: Date]) -> [SyncOp] {
        let now = Date()
        cutoffs.merge(scopeCutoffs.mapValues { min($0, now) }, uniquingKeysWith: max)
        return discard { Self.isCutOff($0, by: scopeCutoffs) }
    }

    nonisolated static func isCutOff(_ op: SyncOp, by cutoffs: [String: Date]) -> Bool {
        op.scopes.contains { scope in cutoffs[scope].map { op.stamp < $0 } ?? false }
    }

    func requeueParked() {
        loadIfNeeded()
        guard !parked.isEmpty else { return }
        let queuedKeys = Set(entries.map(\.op.dedupKey))
        var stillParked: [OutboxEntry] = []
        for var entry in parked {
            guard !queuedKeys.contains(entry.op.dedupKey) else {
                stillParked.append(entry)
                continue
            }
            entry.attempts = Self.maxAttempts - 1
            entries.append(entry)
        }
        parked = stillParked
        persist()
    }

    /// A course's colour, name or ignore setting the backend cannot place yet, 404
    /// `course_not_found` as the upload that adds the course has not landed, or a colour or name
    /// whose course this device cannot name, waits parked for the next course upload.
    static func parksAtOnce(_ error: Error, for op: SyncOp) -> Bool {
        switch op {
        case .courseOverride where error is CourseKeyUnknownError:
            return true
        case .courseOverride, .courseIgnore:
            guard case PushAPIError.httpStatus(404, _, _) = error else { return false }
            return (error as? PushAPIError)?.code == "course_not_found"
        case .assignmentOverride, .courseDelete, .courseAdd:
            return false
        }
    }

    static func keepsWithoutAttempt(_ error: Error, for op: SyncOp) -> Bool {
        if case .courseAdd = op, case PushAPIError.httpStatus(_, _, _) = error { return false }
        // The backend answers a course delete 409 only for its stamp, so another code is not a
        // refusal of the delete, which a later attempt may still land.
        if case .courseDelete = op, case PushAPIError.httpStatus(409, _, _) = error { return true }
        return keepsWithoutAttempt(error)
    }

    static func keepsWithoutAttempt(_ error: Error) -> Bool {
        switch error {
        case is CancellationError, is URLError:
            return true
        case let auth as SyncOutboxAuthError:
            return auth.statusCode == 401
        case PushAPIError.httpStatus(let code, _, _):
            return code == 408 || code == 429 || (500..<600).contains(code)
        default:
            return false
        }
    }

    @discardableResult
    func drain(
        holding isHeld: @Sendable (SyncOp) -> Bool = { _ in false },
        execute: @Sendable (SyncOp) async throws -> Void
    ) async -> Bool {
        // Iterate a snapshot: the actor is reentrant at `await execute`, so `enqueue` can change
        // `entries` mid-drain; new entries merge back at the end for the next tick. A `clearAll()`
        // mid-drain bumps `generation`: stop and never merge back, or cleared entries resurrect.
        loadIfNeeded()
        let snapshot = entries
        let snapshotIds = Set(snapshot.map(\.id))
        let startGeneration = generation
        var kept: [OutboxEntry] = []
        var index = 0

        func mergeAndStore(retainRemainder fromIndex: Int) {
            guard generation == startGeneration else { return }
            kept.append(contentsOf: snapshot[fromIndex...])
            let newlyEnqueued = entries.filter { !snapshotIds.contains($0.id) }
            let freshKeys = Set(newlyEnqueued.map { $0.op.dedupKey })
            let stillQueued = Set(entries.map(\.id))
            entries = kept.filter { !freshKeys.contains($0.op.dedupKey) && stillQueued.contains($0.id) }
                + newlyEnqueued
            parked.removeAll { freshKeys.contains($0.op.dedupKey) }
            persist()
        }

        while index < snapshot.count {
            guard generation == startGeneration else { return entries.isEmpty }
            let entry = snapshot[index]
            guard entries.contains(where: { $0.id == entry.id }) else {
                index += 1
                continue
            }
            if isHeld(entry.op) {
                kept.append(entry)
                index += 1
                continue
            }

            do {
                try await execute(entry.op)
            } catch {
                guard generation == startGeneration else { return entries.isEmpty }
                if Self.keepsWithoutAttempt(error, for: entry.op) {
                    mergeAndStore(retainRemainder: index)
                    return false
                }
                if Self.parksAtOnce(error, for: entry.op) {
                    park(entry)
                    index += 1
                    continue
                }

                var updated = entry
                updated.attempts += 1
                if updated.attempts < Self.maxAttempts {
                    kept.append(updated)
                } else {
                    giveUp(on: updated, after: error)
                }
            }

            index += 1
        }

        mergeAndStore(retainRemainder: snapshot.count)
        return entries.isEmpty
    }

    private func giveUp(on entry: OutboxEntry, after error: Error) {
        let kind: String
        let parks: Bool
        switch entry.op {
        case .courseOverride: (kind, parks) = ("courseOverride", false)
        case .assignmentOverride: (kind, parks) = ("assignmentOverride", true)
        case .courseIgnore(_, _, _, _, let ignore, _): (kind, parks) = ("courseIgnore", ignore != nil)
        case .courseDelete: (kind, parks) = ("courseDelete", false)
        case .courseAdd: (kind, parks) = ("courseAdd", true)
        }
        logger.warning("Outbox: gave up on \(kind, privacy: .public) after \(Self.maxAttempts) attempts")
        AppLogger.captureError(error, context: ["phase": "cloudSync.outbox.giveUp", "op": kind])
        guard parks else { return }
        park(entry)
    }

    private func park(_ entry: OutboxEntry) {
        guard entries.contains(where: { $0.id == entry.id }) else { return }
        parked.removeAll { $0.op.dedupKey == entry.op.dedupKey }
        parked.append(entry)
    }

    private func loadIfNeeded() {
        guard !isLoaded, let onDisk = files.load() else { return }
        adopt(queued: onDisk.queued, parked: onDisk.parked)
    }

    private func adopt(queued: [OutboxEntry], parked parkedOnDisk: [OutboxEntry]) {
        let newer = Set((entries + parked).map(\.op.dedupKey))
        entries = queued.filter { !newer.contains($0.op.dedupKey) } + entries
        parked = parkedOnDisk.filter { !newer.contains($0.op.dedupKey) } + parked
        isLoaded = true
        persist()
    }

    private func persist() {
        guard isLoaded else { return }
        files.persist(queued: entries, parked: parked)
    }
}

struct SyncOutboxAuthError: Error {
    let statusCode: Int
}
