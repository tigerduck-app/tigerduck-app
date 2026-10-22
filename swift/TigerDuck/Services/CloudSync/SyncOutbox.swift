import Foundation
import os

nonisolated enum SyncOp: Codable, Sendable {
    case courseOverride(semester: String, moodleId: String, customName: String?, colorHex: String?, locale: String?, stamp: Date)
    case assignmentOverride(moodleCourseId: Int, moodleAssignmentId: Int, localStatus: String, stamp: Date)
    case courseIgnore(semester: String, courseNo: String, moodleId: String, moodleCourseId: Int?, ignore: Bool?, stamp: Date)
    case courseDelete(semester: String, courseNo: String, stamp: Date)
    case courseAdd(semester: String, courseNo: String, stamp: Date)

    private enum CodingKeys: String, CodingKey {
        case courseOverride, assignmentOverride, courseIgnore, courseDelete, courseAdd
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
    private enum CourseKeys: String, CodingKey {
        case semester, courseNo, stamp
    }

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
            let c = try container.nestedContainer(keyedBy: CourseKeys.self, forKey: .courseDelete)
            self = .courseDelete(
                semester: try c.decode(String.self, forKey: .semester),
                courseNo: try c.decode(String.self, forKey: .courseNo),
                stamp: try c.decode(Date.self, forKey: .stamp))
        } else if container.contains(.courseAdd) {
            let c = try container.nestedContainer(keyedBy: CourseKeys.self, forKey: .courseAdd)
            self = .courseAdd(
                semester: try c.decode(String.self, forKey: .semester),
                courseNo: try c.decode(String.self, forKey: .courseNo),
                stamp: try c.decode(Date.self, forKey: .stamp))
        } else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown SyncOp case"))
        }
    }

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
        case .courseAdd(let semester, let courseNo, _):
            return "ca|\(semester)|\(courseNo)"
        }
    }
}

nonisolated enum ResolvedSyncOp: Sendable {
    case courseOverride(courseId: String, colorHex: String?, customName: String?, locale: String?)
    case assignmentOverride(assignmentId: Int, localStatus: String)
    case courseIgnore(courseId: String, moodleCourseId: Int?, ignore: Bool?)
    case courseDelete(courseKey: String)
    case courseAdd(semester: String, courseNo: String)
}

nonisolated struct OutboxEntry: Codable, Sendable {
    let id: UUID
    let op: SyncOp
    var attempts: Int
}

actor SyncOutbox {
    static let maxAttempts = 5

    private let directory: URL
    private let read: @Sendable (URL) throws -> Data
    private var entries: [OutboxEntry] = []
    private var parked: [OutboxEntry] = []
    private var generation = 0
    private var isLoaded: Bool
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
        isLoaded = true
        generation += 1
        persist()
    }

    func discard(where isDropped: @Sendable (SyncOp) -> Bool) {
        loadIfNeeded()
        entries.removeAll { isDropped($0.op) }
        parked.removeAll { isDropped($0.op) }
        persist()
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

    static func keepsWithoutAttempt(_ error: Error, for op: SyncOp) -> Bool {
        if case .courseAdd = op, case PushAPIError.httpStatus(_, _) = error { return false }
        return keepsWithoutAttempt(error)
    }

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

    @discardableResult
    func drain(
        holding isHeld: @Sendable (SyncOp) -> Bool = { _ in false },
        execute: @Sendable (ResolvedSyncOp) async throws -> Void
    ) async -> Bool {
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
                try await execute(resolve(entry.op))
            } catch {
                guard generation == startGeneration else { return entries.isEmpty }
                if Self.keepsWithoutAttempt(error, for: entry.op) {
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
        guard parks, entries.contains(where: { $0.id == entry.id }) else { return }
        parked.removeAll { $0.op.dedupKey == entry.op.dedupKey }
        parked.append(entry)
    }

    private func resolve(_ op: SyncOp) -> ResolvedSyncOp {
        switch op {
        case .courseOverride(_, let moodleId, let customName, let colorHex, let locale, _):
            let resolvedLocale = customName != nil
                ? (locale ?? Locale.current.language.languageCode?.identifier)
                : nil
            return .courseOverride(courseId: moodleId, colorHex: colorHex, customName: customName, locale: resolvedLocale)

        case .assignmentOverride(_, let moodleAssignmentId, let localStatus, _):
            return .assignmentOverride(assignmentId: moodleAssignmentId, localStatus: localStatus)

        case .courseIgnore(_, _, let moodleId, let moodleCourseId, let ignore, _):
            return .courseIgnore(courseId: moodleId, moodleCourseId: moodleCourseId, ignore: ignore)

        case .courseDelete(let semester, let courseNo, _):
            return .courseDelete(courseKey: CourseTombstone.serverKey(semester: semester, courseNo: courseNo))

        case .courseAdd(let semester, let courseNo, _):
            return .courseAdd(semester: semester, courseNo: courseNo)
        }
    }

    private static let fileName = "outbox.json"
    private static let parkedFileName = "outbox-parked.json"

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

    private struct FailableEntry: Decodable {
        let entry: OutboxEntry?
        init(from decoder: Decoder) throws {
            entry = try? OutboxEntry(from: decoder)
        }
    }

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

struct SyncOutboxAuthError: Error {
    let statusCode: Int
}
