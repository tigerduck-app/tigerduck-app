import Foundation
import os

// MARK: - SyncOp

/// Pending local change waiting to be pushed to the server.
nonisolated enum SyncOp: Codable, Sendable {
    case courseOverride(semester: String, courseKey: String, customName: String?, colorHex: String?, stamp: Date)
    case assignmentOverride(moodleCourseId: Int, moodleAssignmentId: Int, localStatus: String, stamp: Date)
    case uploadSnapshot

    /// Ops with the same dedupKey replace each other (last writer wins).
    /// courseOverride keys include the field set so simultaneous name and
    /// color edits can coexist in the queue.
    var dedupKey: String {
        switch self {
        case .courseOverride(let semester, let courseKey, let customName, let colorHex, _):
            let fields = [
                customName != nil ? "n" : "",
                colorHex != nil ? "c" : "",
            ].joined()
            return "co|\(semester)|\(courseKey)|\(fields)"
        case .assignmentOverride(let moodleCourseId, let moodleAssignmentId, _, _):
            return "ao|\(moodleCourseId)|\(moodleAssignmentId)"
        case .uploadSnapshot:
            return "upload"
        }
    }
}

// MARK: - ResolvedSyncOp

/// What the executor receives after server IDs are resolved via SyncIdMap.
nonisolated enum ResolvedSyncOp: Sendable {
    case courseOverride(courseId: String, colorHex: String?, customName: String?, locale: String?)
    case assignmentOverride(assignmentId: Int, localStatus: String)
    case uploadSnapshot
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
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "CloudSync.Outbox")

    init(directory: URL = SyncIdMap.defaultDirectory()) {
        self.directory = directory
        self.entries = Self.loadEntries(from: directory)
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
        persist()
    }

    // MARK: - Drain

    /// Process entries in order via the provided executor.
    /// Returns `true` if the queue is empty at the end.
    @discardableResult
    func drain(
        idMap: SyncIdMap,
        execute: @Sendable (ResolvedSyncOp) async throws -> Void
    ) async -> Bool {
        var kept: [OutboxEntry] = []
        var index = 0

        while index < entries.count {
            let entry = entries[index]

            guard let resolved = resolve(entry.op, idMap: idMap) else {
                kept.append(entry)
                index += 1
                continue
            }

            do {
                try await execute(resolved)
            } catch is CancellationError {
                kept.append(entry)
                kept.append(contentsOf: entries[(index + 1)...])
                entries = kept
                persist()
                return false
            } catch is URLError {
                kept.append(entry)
                kept.append(contentsOf: entries[(index + 1)...])
                entries = kept
                persist()
                return false
            } catch {
                let statusCode = (error as? SyncOutboxAuthError)?.statusCode
                if statusCode == 401 {
                    kept.append(entry)
                    kept.append(contentsOf: entries[(index + 1)...])
                    entries = kept
                    persist()
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

        entries = kept
        persist()
        return entries.isEmpty
    }

    // MARK: - Resolution

    private func resolve(_ op: SyncOp, idMap: SyncIdMap) -> ResolvedSyncOp? {
        switch op {
        case .courseOverride(let semester, let courseKey, let customName, let colorHex, _):
            let moodleId = "client:\(semester):\(courseKey)"
            let locale = customName != nil ? Locale.current.language.languageCode?.identifier : nil
            return .courseOverride(courseId: moodleId, colorHex: colorHex, customName: customName, locale: locale)

        case .assignmentOverride(_, let moodleAssignmentId, let localStatus, _):
            return .assignmentOverride(assignmentId: moodleAssignmentId, localStatus: localStatus)

        case .uploadSnapshot:
            return .uploadSnapshot
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

    private static func loadEntries(from directory: URL) -> [OutboxEntry] {
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let entries = try? JSONDecoder().decode([OutboxEntry].self, from: data) else {
            Logger(subsystem: "org.ntust.app.TigerDuck", category: "CloudSync.Outbox")
                .warning("outbox.json decode failed — starting empty")
            return []
        }
        return entries
    }
}

/// Thrown by the executor when the API returns 401 so the outbox drain aborts.
struct SyncOutboxAuthError: Error {
    let statusCode: Int
}
