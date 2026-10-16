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
    /// Ignores every assignment of a course, or stops, by the same `moodleId` as
    /// `courseOverride`. `moodleCourseId` is the numeric Moodle id; with `ignore` nil the op
    /// sends that id alone, to a server that ignores the course without it.
    case courseIgnore(semester: String, courseNo: String, moodleId: String, moodleCourseId: Int?, ignore: Bool?, stamp: Date)
    /// Deletes a course hidden here from the server, which keeps listing it until this lands.
    case courseDelete(semester: String, courseNo: String, stamp: Date)

    private enum CodingKeys: String, CodingKey {
        case courseOverride, assignmentOverride, courseIgnore, courseDelete
    }
    private enum CourseOverrideKeys: String, CodingKey {
        case semester, moodleId, courseKey, customName, colorHex, locale, stamp
    }
    private enum AssignmentOverrideKeys: String, CodingKey {
        case moodleCourseId, moodleAssignmentId, localStatus, stamp
    }
    private enum CourseIgnoreKeys: String, CodingKey {
        case semester, courseNo, moodleId, moodleCourseId, ignore, stamp
    }
    private enum CourseDeleteKeys: String, CodingKey {
        case semester, courseNo, stamp
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
        } else if container.contains(.courseIgnore) {
            let c = try container.nestedContainer(keyedBy: CourseIgnoreKeys.self, forKey: .courseIgnore)
            self = .courseIgnore(
                semester: try c.decode(String.self, forKey: .semester),
                courseNo: try c.decode(String.self, forKey: .courseNo),
                moodleId: try c.decode(String.self, forKey: .moodleId),
                moodleCourseId: try c.decodeIfPresent(Int.self, forKey: .moodleCourseId),
                ignore: try c.decodeIfPresent(Bool.self, forKey: .ignore),
                stamp: try c.decode(Date.self, forKey: .stamp))
        } else if container.contains(.courseDelete) {
            let c = try container.nestedContainer(keyedBy: CourseDeleteKeys.self, forKey: .courseDelete)
            self = .courseDelete(
                semester: try c.decode(String.self, forKey: .semester),
                courseNo: try c.decode(String.self, forKey: .courseNo),
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
        case .courseIgnore(let semester, _, let moodleId, _, _, _):
            return "ci|\(semester)|\(moodleId)"
        case .courseDelete(let semester, let courseNo, _):
            return "cd|\(semester)|\(courseNo)"
        }
    }
}

// MARK: - ResolvedSyncOp

/// What the executor receives: the queued op flattened to the Moodle
/// identifiers the override PATCH endpoints resolve directly.
nonisolated enum ResolvedSyncOp: Sendable {
    case courseOverride(courseId: String, colorHex: String?, customName: String?, locale: String?)
    case assignmentOverride(assignmentId: Int, localStatus: String)
    case courseIgnore(courseId: String, moodleCourseId: Int?, ignore: Bool?)
    case courseDelete(courseKey: String)
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
    static let maxAttempts = 5

    private let directory: URL
    private let read: @Sendable (URL) throws -> Data
    private var entries: [OutboxEntry] = []
    /// Marks the server refused `maxAttempts` times. A pull still treats each as an edit on its
    /// way up, so the local status stands, and `requeueParked()` gives it one more try per full
    /// sync until it lands, as `AcademicCalendarStore.unacknowledgedHolidayIDs` does for holidays.
    private var parked: [OutboxEntry] = []
    /// Bumped by `clearAll()`. A drain suspended at `await execute` when the
    /// queue is cleared must not merge its retained entries back afterwards.
    private var generation = 0
    /// False while a queue file exists but could not be read, as at a launch behind the lock
    /// screen (`completeFileProtectionUnlessOpen`). Until it is read, or `loadOrGiveUp` gives up
    /// on it, nothing is written over the files, and what was queued meanwhile joins what they hold.
    private var isLoaded: Bool
    /// Reads `loadOrGiveUp` found the files unreadable with protected data available.
    private var unreadableLoads = 0
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "CloudSync.Outbox")

    init(
        directory: URL = SyncOutbox.defaultDirectory(),
        read: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) {
        self.directory = directory
        self.read = read
        let queued = Self.loadEntries(from: directory, fileName: Self.fileName, read: read)
        let parked = Self.loadEntries(from: directory, fileName: Self.parkedFileName, read: read)
        // Both or neither, so a retry takes each file whole.
        let loaded = queued != nil && parked != nil
        self.entries = loaded ? queued ?? [] : []
        self.parked = loaded ? parked ?? [] : []
        self.isLoaded = loaded
    }

    static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TigerDuckCloudSync", isDirectory: true)
    }

    func enqueue(_ op: SyncOp) {
        loadIfNeeded()
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

    /// For a caller that can tell whether protected data is available, which this actor cannot
    /// ask. A queue file still unreadable with it available is damaged or has the wrong
    /// permissions rather than waiting for an unlock. After `unreadableLoadLimit` such reads the
    /// outbox stops waiting: it keeps what it can read and what was queued since, and its next
    /// write replaces the files, so those edits survive a relaunch.
    func loadOrGiveUp(protectedDataAvailable: Bool) {
        guard !isLoaded else { return }
        let queued = Self.loadEntries(from: directory, fileName: Self.fileName, read: read)
        let parkedOnDisk = Self.loadEntries(from: directory, fileName: Self.parkedFileName, read: read)
        if let queued, let parkedOnDisk {
            adopt(queued: queued, parked: parkedOnDisk)
            return
        }
        guard protectedDataAvailable else { return }
        unreadableLoads += 1
        guard unreadableLoads >= Self.unreadableLoadLimit else { return }
        logger.error("Outbox: queue files unreadable while protected data is available, giving up on them")
        adopt(queued: queued ?? [], parked: parkedOnDisk ?? [])
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
        // Sign-out empties the files whether or not they were read.
        isLoaded = true
        generation += 1
        persist()
    }

    /// Drops the queued and parked ops `isDropped` names, edits the user chose to throw away. A
    /// drain under way keeps none of them; one already sent stays sent.
    func discard(where isDropped: @Sendable (SyncOp) -> Bool) {
        loadIfNeeded()
        entries.removeAll { isDropped($0.op) }
        parked.removeAll { isDropped($0.op) }
        persist()
    }

    /// Queues every parked mark again with one attempt left. One whose old copy a drain still
    /// holds stays parked: that drain drops the copy when it ends, so requeuing would lose both.
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

    /// Errors that say nothing about the edit: no network, a cancelled drain, a session to renew,
    /// or a server that is down or busy. The entry waits for a later drain without an attempt.
    static func keepsWithoutAttempt(_ error: Error) -> Bool {
        switch error {
        case is CancellationError, is URLError:
            return true
        case let auth as SyncOutboxAuthError:
            return auth.statusCode == 401
        case PushAPIError.httpStatus(let code, _):
            return code == 408 || code == 429 || (500..<600).contains(code)
        default:
            return false
        }
    }

    // MARK: - Drain

    /// Process entries in order via the provided executor, leaving the ones `isHeld` names
    /// queued and untried. Returns `true` if the queue is empty at the end.
    @discardableResult
    func drain(
        holding isHeld: @Sendable (SyncOp) -> Bool = { _ in false },
        execute: @Sendable (ResolvedSyncOp) async throws -> Void
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
            // A mid-drain enqueue can share a dedupKey with a retained entry. The new op is the
            // last writer, so drop the retained entry it supersedes; keeping both would make the
            // next drain PATCH the stale value before the fresh one. A discarded one goes too.
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
            // Discarded or superseded since the snapshot: not sent.
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
                try await execute(resolve(entry.op))
            } catch {
                // A `clearAll()` during the request removed the entry; keeping or parking
                // it now would bring it back.
                guard generation == startGeneration else { return entries.isEmpty }
                if Self.keepsWithoutAttempt(error) {
                    mergeAndStore(retainRemainder: index)
                    return false
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

    /// Reports an entry the server refused `maxAttempts` times. A mark or a course's ignore
    /// setting is parked; a course override, a course delete, or a numeric course id sent alone,
    /// is dropped: the next full sync applies the server's colour, name or course over it, and
    /// sends the id again.
    private func giveUp(on entry: OutboxEntry, after error: Error) {
        let kind: String
        let parks: Bool
        switch entry.op {
        case .courseOverride: (kind, parks) = ("courseOverride", false)
        case .assignmentOverride: (kind, parks) = ("assignmentOverride", true)
        case .courseIgnore(_, _, _, _, let ignore, _): (kind, parks) = ("courseIgnore", ignore != nil)
        case .courseDelete: (kind, parks) = ("courseDelete", false)
        }
        logger.warning("Outbox: gave up on \(kind, privacy: .public) after \(Self.maxAttempts) attempts")
        AppLogger.captureError(error, context: ["phase": "cloudSync.outbox.giveUp", "op": kind])
        // One discarded or superseded while its request was out is not parked either.
        guard parks, entries.contains(where: { $0.id == entry.id }) else { return }
        parked.removeAll { $0.op.dedupKey == entry.op.dedupKey }
        parked.append(entry)
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

        case .courseIgnore(_, _, let moodleId, let moodleCourseId, let ignore, _):
            return .courseIgnore(courseId: moodleId, moodleCourseId: moodleCourseId, ignore: ignore)

        case .courseDelete(let semester, let courseNo, _):
            // The Moodle idnumber, which PATCH .../override takes, deletes nothing.
            return .courseDelete(courseKey: CourseTombstone.serverKey(semester: semester, courseNo: courseNo))
        }
    }

    // MARK: - Persistence

    private static let fileName = "outbox.json"
    /// Apart from `fileName`, which a build without parking would read as queued edits.
    private static let parkedFileName = "outbox-parked.json"

    /// Reads the files the init could not. What was queued since stays, after what they hold, and
    /// replaces an op of theirs with the same key.
    private func loadIfNeeded() {
        guard !isLoaded,
              let queued = Self.loadEntries(from: directory, fileName: Self.fileName, read: read),
              let parkedOnDisk = Self.loadEntries(from: directory, fileName: Self.parkedFileName, read: read)
        else { return }
        adopt(queued: queued, parked: parkedOnDisk)
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
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (list, name) in [(entries, Self.fileName), (parked, Self.parkedFileName)] {
                let data = try JSONEncoder().encode(list)
                try data.write(
                    to: directory.appendingPathComponent(name),
                    options: [.atomic, .completeFileProtectionUnlessOpen]
                )
            }
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

    /// Nil when the file exists but cannot be read now; none when it is missing or undecodable.
    private static func loadEntries(
        from directory: URL,
        fileName: String,
        read: (URL) throws -> Data
    ) -> [OutboxEntry]? {
        let url = directory.appendingPathComponent(fileName)
        let data: Data
        do {
            data = try read(url)
        } catch {
            return FileManager.default.fileExists(atPath: url.path) ? nil : []
        }
        let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "CloudSync.Outbox")
        guard let wrapped = try? JSONDecoder().decode([FailableEntry].self, from: data) else {
            logger.warning("\(fileName, privacy: .public) decode failed — starting empty")
            return []
        }
        let entries = wrapped.compactMap(\.entry)
        if entries.count != wrapped.count {
            logger.warning("\(fileName, privacy: .public): dropped \(wrapped.count - entries.count, privacy: .public) undecodable entries")
        }
        return entries
    }
}

/// Thrown by the executor when the API returns 401 so the outbox drain aborts.
struct SyncOutboxAuthError: Error {
    let statusCode: Int
}
