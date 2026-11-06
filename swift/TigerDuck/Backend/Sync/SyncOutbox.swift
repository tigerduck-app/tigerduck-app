import Foundation
import os

actor SyncOutbox {
    static let maxAttempts = 5

    private let files: OutboxFiles
    private var entries: [OutboxEntry] = []
    private var parked: [OutboxEntry] = []
    private var clearGeneration = 0
    private var loadState: LoadState
    private var unreadableLoads = 0
    private var cutoffs = DiscardCutoffs()

    private enum LoadState {
        case loaded
        case filesUnreadable
    }

    nonisolated enum Pause: Sendable {
        case beforeEnqueue
        case afterRead
    }

    private let pause: (@Sendable (Pause) async -> Void)?
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "CloudSync.Outbox")

    init(
        directory: URL = OutboxFiles.defaultDirectory(),
        read: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) },
        pause: (@Sendable (Pause) async -> Void)? = nil
    ) {
        files = OutboxFiles(directory: directory, read: read)
        self.pause = pause
        switch files.load() {
        case .read(let queued, let parked):
            entries = queued
            self.parked = parked
            loadState = .loaded
        case .unreadable:
            loadState = .filesUnreadable
        }
    }

    func enqueue(_ op: SyncOp, for signIn: SignIn) async {
        if let pause { await pause(.beforeEnqueue) }
        loadIfNeeded()
        guard signIn.isCurrent, !cutoffs.cutsOff(op) else { return }
        let key = op.dedupKey
        entries.removeAll { $0.op.dedupKey == key }
        parked.removeAll { $0.op.dedupKey == key }
        entries.append(OutboxEntry(id: UUID(), op: op, attempts: 0, signIn: signIn))
        persist()
    }

    func pendingCount() -> Int {
        loadIfNeeded()
        return entries.count
    }

    static let unreadableLoadLimit = 3

    func loadOrGiveUp(protectedDataAvailable: Bool) {
        guard loadState == .filesUnreadable else { return }
        if case .read(let queued, let parked) = files.load() {
            adopt(queued: queued, parked: parked)
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

    func queuedAndParked() async -> [OutboxEntry] {
        loadIfNeeded()
        let read = entries + parked
        if let pause { await pause(.afterRead) }
        return read
    }

    func clearAll() {
        entries = []
        parked = []
        cutoffs = DiscardCutoffs()
        loadState = .loaded
        clearGeneration += 1
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

    @discardableResult
    func discard(madeBefore scopeCutoffs: [DiscardScope: Date]) -> [SyncOp] {
        cutoffs.keep(scopeCutoffs, notAfter: Date())
        let discarding = DiscardCutoffs(scopeCutoffs)
        return discard { discarding.cutsOff($0) }
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

    /// Sends each op for the sign-in it was made in; `signIn` stands in for an entry read from disk.
    @discardableResult
    func drain(
        for signIn: SignIn,
        holding isHeld: @Sendable (SyncOp) -> Bool = { _ in false },
        execute: @Sendable (SyncOp, SignIn) async throws -> Void
    ) async -> Bool {
        loadIfNeeded()
        let snapshot = entries
        let snapshotIds = Set(snapshot.map(\.id))
        let startGeneration = clearGeneration
        var kept: [OutboxEntry] = []
        var index = 0

        func mergeAndStore(retainRemainder fromIndex: Int) {
            guard clearGeneration == startGeneration else { return }
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
            guard clearGeneration == startGeneration else { return entries.isEmpty }
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
                try await execute(entry.op, entry.signIn ?? signIn)
            } catch {
                guard clearGeneration == startGeneration else { return entries.isEmpty }
                if error is ResendHeldError {
                    kept.append(entry)
                    index += 1
                    continue
                }
                if OutboxErrorPolicy.keepsWithoutAttempt(error, for: entry.op) {
                    mergeAndStore(retainRemainder: index)
                    return false
                }
                if OutboxErrorPolicy.waitsForCourseUpload(error, for: entry.op) {
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
        guard loadState == .filesUnreadable, case .read(let queued, let parked) = files.load() else { return }
        adopt(queued: queued, parked: parked)
    }

    private func adopt(queued: [OutboxEntry], parked parkedOnDisk: [OutboxEntry]) {
        let newer = Set((entries + parked).map(\.op.dedupKey))
        entries = queued.filter { !newer.contains($0.op.dedupKey) } + entries
        parked = parkedOnDisk.filter { !newer.contains($0.op.dedupKey) } + parked
        loadState = .loaded
        persist()
    }

    private func persist() {
        guard loadState == .loaded else { return }
        files.persist(queued: entries, parked: parked)
    }
}

struct SyncOutboxAuthError: Error {
    let statusCode: Int
}
