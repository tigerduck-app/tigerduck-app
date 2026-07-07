import Foundation
import os

// MARK: - SyncOp

/// Pending local change waiting to be pushed to the server.
nonisolated enum SyncOp: Codable, Sendable {
    /// `moodleId` is the course's Moodle idnumber (or the server's
    /// `{semester}{courseNo}` fallback) — the value the override endpoint
    /// resolves against. It is NOT the `client:{semester}:{courseNo}`
    /// course_key, which that endpoint never consults.
    case courseOverride(semester: String, moodleId: String, customName: String?, colorHex: String?, locale: String?, stamp: Date)
    case assignmentOverride(moodleCourseId: Int, moodleAssignmentId: Int, localStatus: String, stamp: Date)

    private enum CodingKeys: String, CodingKey {
        case courseOverride, assignmentOverride
    }
    private enum CourseOverrideKeys: String, CodingKey {
        case semester, moodleId, courseKey, customName, colorHex, locale, stamp
    }
    private enum AssignmentOverrideKeys: String, CodingKey {
        case moodleCourseId, moodleAssignmentId, localStatus, stamp
    }

    /// Manual decode only: `moodleId` was persisted as `courseKey` before the
    /// rename, and a failed decode wipes the whole outbox file — so fall back
    /// to the old key. Encoding stays synthesized (writes `moodleId`).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.courseOverride) {
            let c = try container.nestedContainer(keyedBy: CourseOverrideKeys.self, forKey: .courseOverride)
            let moodleId = try c.decodeIfPresent(String.self, forKey: .moodleId)
                ?? c.decode(String.self, forKey: .courseKey)
            self = .courseOverride(
                semester: try c.decode(String.self, forKey: .semester),
                moodleId: moodleId,
                customName: try c.decodeIfPresent(String.self, forKey: .customName),
                colorHex: try c.decodeIfPresent(String.self, forKey: .colorHex),
                locale: try c.decodeIfPresent(String.self, forKey: .locale),
                stamp: try c.decode(Date.self, forKey: .stamp))
        } else if container.contains(.assignmentOverride) {
            let c = try container.nestedContainer(keyedBy: AssignmentOverrideKeys.self, forKey: .assignmentOverride)
            self = .assignmentOverride(
                moodleCourseId: try c.decode(Int.self, forKey: .moodleCourseId),
                moodleAssignmentId: try c.decode(Int.self, forKey: .moodleAssignmentId),
                localStatus: try c.decode(String.self, forKey: .localStatus),
                stamp: try c.decode(Date.self, forKey: .stamp))
        } else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown SyncOp case"))
        }
    }

    /// Ops with the same dedupKey replace each other (last writer wins).
    /// courseOverride keys include the field set (and the locale for name
    /// edits) so simultaneous name and color edits — and per-locale custom
    /// names — can coexist in the queue rather than evicting each other.
    var dedupKey: String {
        switch self {
        case .courseOverride(let semester, let moodleId, let customName, let colorHex, let locale, _):
            let fields = [
                customName != nil ? "n" : "",
                colorHex != nil ? "c" : "",
            ].joined()
            return "co|\(semester)|\(moodleId)|\(fields)|\(locale ?? "")"
        case .assignmentOverride(let moodleCourseId, let moodleAssignmentId, _, _):
            return "ao|\(moodleCourseId)|\(moodleAssignmentId)"
        }
    }
}

// MARK: - ResolvedSyncOp

/// What the executor receives: the queued op flattened to the Moodle
/// identifiers the override PATCH endpoints resolve directly.
nonisolated enum ResolvedSyncOp: Sendable {
    case courseOverride(courseId: String, colorHex: String?, customName: String?, locale: String?)
    case assignmentOverride(assignmentId: Int, localStatus: String)
}

// MARK: - OutboxEntry

nonisolated struct OutboxEntry: Codable, Sendable {
    let id: UUID
    let op: SyncOp
    var attempts: Int
}

// MARK: - SyncOutbox

/// Persisted outbound-operation queue. Survives app restarts.
actor SyncOutbox {
    private static let maxAttempts = 5

    private let directory: URL
    private var entries: [OutboxEntry] = []
    /// Bumped by `clearAll()`. A drain suspended at `await execute` when the
    /// queue is cleared must not merge its retained entries back afterwards.
    private var generation = 0
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "CloudSync.Outbox")

    init(directory: URL = SyncOutbox.defaultDirectory()) {
        self.directory = directory
        self.entries = Self.loadEntries(from: directory)
    }

    static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TigerDuckCloudSync", isDirectory: true)
    }

    func enqueue(_ op: SyncOp) {
        let key = op.dedupKey
        entries.removeAll { $0.op.dedupKey == key }
        entries.append(OutboxEntry(id: UUID(), op: op, attempts: 0))
        persist()
    }

    func pendingCount() -> Int { entries.count }

    func snapshot() -> [OutboxEntry] { entries }

    func clearAll() {
        entries = []
        generation += 1
        persist()
    }

    // MARK: - Drain

    /// Process entries in order via the provided executor.
    /// Returns `true` if the queue is empty at the end.
    @discardableResult
    func drain(
        execute: @Sendable (ResolvedSyncOp) async throws -> Void
    ) async -> Bool {
        // Iterate over a snapshot: the actor is reentrant at `await execute`,
        // so `enqueue` can mutate `entries` mid-drain. Entries added during
        // the drain are merged back at the end and handled on the next tick.
        // A `clearAll()` during the drain bumps `generation`: stop executing
        // and never merge back, or the drain would resurrect cleared entries.
        let snapshot = entries
        let snapshotIds = Set(snapshot.map(\.id))
        let startGeneration = generation
        var kept: [OutboxEntry] = []
        var index = 0

        func mergeAndStore(retainRemainder fromIndex: Int) {
            guard generation == startGeneration else { return }
            kept.append(contentsOf: snapshot[fromIndex...])
            let newlyEnqueued = entries.filter { !snapshotIds.contains($0.id) }
            // A mid-drain enqueue may share a dedupKey with a retained entry
            // (e.g. a new color pick while the old PATCH was still failing).
            // The newly-enqueued op is the last writer, so drop any retained
            // entry it supersedes — otherwise both persist and the next drain
            // PATCHes the stale value before the fresh one.
            let freshKeys = Set(newlyEnqueued.map { $0.op.dedupKey })
            entries = kept.filter { !freshKeys.contains($0.op.dedupKey) } + newlyEnqueued
            persist()
        }

        while index < snapshot.count {
            guard generation == startGeneration else { return entries.isEmpty }
            let entry = snapshot[index]

            do {
                try await execute(resolve(entry.op))
            } catch is CancellationError {
                mergeAndStore(retainRemainder: index)
                return false
            } catch is URLError {
                mergeAndStore(retainRemainder: index)
                return false
            } catch {
                let statusCode = (error as? SyncOutboxAuthError)?.statusCode
                if statusCode == 401 {
                    mergeAndStore(retainRemainder: index)
                    return false
                }

                var updated = entry
                updated.attempts += 1
                if updated.attempts < Self.maxAttempts {
                    kept.append(updated)
                } else {
                    logger.warning("Outbox: dropping entry \(entry.id, privacy: .public) after \(Self.maxAttempts) attempts — key: \(entry.op.dedupKey, privacy: .public)")
                }
            }

            index += 1
        }

        mergeAndStore(retainRemainder: snapshot.count)
        return entries.isEmpty
    }

    // MARK: - Resolution

    private func resolve(_ op: SyncOp) -> ResolvedSyncOp {
        switch op {
        case .courseOverride(_, let moodleId, let customName, let colorHex, let locale, _):
            // Use the locale the name was stored under. Legacy queued ops
            // predate locale tracking (decode to nil) — fall back to the
            // device locale so the name still carries a tag.
            let resolvedLocale = customName != nil
                ? (locale ?? Locale.current.language.languageCode?.identifier)
                : nil
            return .courseOverride(courseId: moodleId, colorHex: colorHex, customName: customName, locale: resolvedLocale)

        case .assignmentOverride(_, let moodleAssignmentId, let localStatus, _):
            return .assignmentOverride(assignmentId: moodleAssignmentId, localStatus: localStatus)
        }
    }

    // MARK: - Persistence

    private static let fileName = "outbox.json"

    private func persist() {
        let url = directory.appendingPathComponent(Self.fileName)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entries)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        } catch {
            logger.error("Outbox: persist failed: \(error)")
        }
    }

    /// Decodes each entry independently so one undecodable entry (unknown
    /// op case, schema drift) drops only itself, never the whole queue.
    private struct FailableEntry: Decodable {
        let entry: OutboxEntry?
        init(from decoder: Decoder) throws {
            entry = try? OutboxEntry(from: decoder)
        }
    }

    private static func loadEntries(from directory: URL) -> [OutboxEntry] {
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return [] }
        let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "CloudSync.Outbox")
        guard let wrapped = try? JSONDecoder().decode([FailableEntry].self, from: data) else {
            logger.warning("outbox.json decode failed — starting empty")
            return []
        }
        let entries = wrapped.compactMap(\.entry)
        if entries.count != wrapped.count {
            logger.warning("outbox.json: dropped \(wrapped.count - entries.count, privacy: .public) undecodable entries")
        }
        return entries
    }
}

/// Thrown by the executor when the API returns 401 so the outbox drain aborts.
struct SyncOutboxAuthError: Error {
    let statusCode: Int
}
