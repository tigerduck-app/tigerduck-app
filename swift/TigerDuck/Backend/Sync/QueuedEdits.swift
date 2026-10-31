import Foundation

/// The edits on their way into the outbox and the ones queued there, with the times a discard or
/// another device's course reset dropped edits by; `CloudSyncCoordinator` forwards its edit
/// questions here.
@MainActor
final class QueuedEdits {
    private let outbox: SyncOutbox
    private var overridesEnqueuing: [UUID: SyncOp] = [:]
    private(set) var overrideEdits = 0
    private var lastColorEdit: [String: Int] = [:]
    private var lastNameEdit: [String: Int] = [:]
    private var addsEnqueuing: [UUID: String] = [:]
    private var addTimes: [String: Date] = [:]
    private(set) var cutoffs: [String: Date] = [:]

    init(outbox: SyncOutbox) {
        self.outbox = outbox
    }

    func enqueueOverride(_ op: SyncOp) -> Task<Void, Never> {
        if case .courseOverride(_, let moodleId, let customName, let colorHex, _, _) = op {
            overrideEdits += 1
            if colorHex != nil { lastColorEdit[moodleId] = overrideEdits }
            if customName != nil { lastNameEdit[moodleId] = overrideEdits }
        }
        let id = UUID()
        overridesEnqueuing[id] = op
        return Task {
            await outbox.enqueue(op)
            overridesEnqueuing[id] = nil
        }
    }

    /// The count of override edits when the last colour edit of `identity` was queued.
    func colorEdit(of identity: String) -> Int {
        lastColorEdit[identity, default: 0]
    }

    func pendingAssignmentOverrideIds() async -> Set<String> {
        var ids = Set<String>()
        for entry in await outbox.snapshot() + outbox.parkedSnapshot() {
            if case .assignmentOverride(_, let moodleAssignmentId, _, _) = entry.op {
                ids.insert(String(moodleAssignmentId))
            }
        }
        return ids
    }

    func holdsUnsentEdits() async -> Bool {
        if !overridesEnqueuing.isEmpty || !addsEnqueuing.isEmpty { return true }
        return await outbox.holdsEntries()
    }

    func pendingCourseOverrides() async -> (colors: Set<String>, names: Set<String>, edits: Int) {
        var pending: (colors: Set<String>, names: Set<String>, edits: Int) = ([], [], overrideEdits)
        for op in await outbox.snapshot().map(\.op) + overridesEnqueuing.values {
            guard case .courseOverride(_, let moodleId, let customName, let colorHex, _, _) = op else { continue }
            if colorHex != nil { pending.colors.insert(moodleId) }
            if customName != nil { pending.names.insert(moodleId) }
        }
        return pending
    }

    func courseOverrides(queuedAfter reading: Int) -> (colors: Set<String>, names: Set<String>) {
        (Set(lastColorEdit.filter { $0.value > reading }.keys), Set(lastNameEdit.filter { $0.value > reading }.keys))
    }

    func courseOverridesToHold(
        since pending: (colors: Set<String>, names: Set<String>, edits: Int)
    ) -> (colors: Set<String>, names: Set<String>) {
        let edited = courseOverrides(queuedAfter: pending.edits)
        return (pending.colors.union(edited.colors), pending.names.union(edited.names))
    }

    /// Use Server for `categories`: drops this device's edits of them made so far.
    func discardEdits(of categories: Set<String>, courseIgnores: Bool) async {
        var scopes = categories.intersection(["assignments", "course_colors", "course_names"])
        if categories.contains("courses") { scopes.insert("ca") }
        if courseIgnores && categories.contains("assignments") { scopes.insert("course_ignores") }
        overridesEnqueuing = overridesEnqueuing.filter { scopes.isDisjoint(with: $0.value.scopes) }
        if scopes.contains("ca") { addsEnqueuing = [:] }
        let now = Date()
        await discard(madeBefore: Dictionary(uniqueKeysWithValues: scopes.map { ($0, now) }))
    }

    /// Discards by time in the outbox, and refuses those ops at `execute` too: a drain picks its
    /// op on the outbox, so it can be on its way to `execute` with one the discard dropped.
    @discardableResult
    private func discard(madeBefore scopeCutoffs: [String: Date]) async -> [SyncOp] {
        let now = Date()
        cutoffs.merge(scopeCutoffs.mapValues { min($0, now) }, uniquingKeysWith: max)
        return await outbox.discard(madeBefore: scopeCutoffs)
    }

    func discardCourseIgnores(semester: String?, courseNo: String?) async {
        await outbox.discard { op in
            guard case .courseIgnore(let opSemester, let opCourseNo, _, _, _, _) = op else { return false }
            return (semester == nil || semester == opSemester) && (courseNo == nil || courseNo == opCourseNo)
        }
    }

    func pendingCourseIgnoreKeys() async -> Set<String> {
        var keys = Set<String>()
        for entry in await outbox.snapshot() + outbox.parkedSnapshot() {
            if case .courseIgnore(let semester, let courseNo, _, _, .some, _) = entry.op {
                keys.insert(CourseTombstone.key(semester: semester, courseNo: courseNo))
            }
        }
        return keys
    }

    func courseDeletes<Fetched>(
        around fetch: () async throws -> Fetched
    ) async rethrows -> (fetched: Fetched, deleting: Set<String>) {
        let before = await pendingCourseDeleteKeys()
        let fetched = try await fetch()
        return (fetched, before.union(await pendingCourseDeleteKeys()))
    }

    func pendingCourseDeleteKeys() async -> Set<String> {
        var keys = Set<String>()
        for entry in await outbox.snapshot() {
            if case .courseDelete(let semester, let courseNo, _) = entry.op {
                keys.insert(CourseTombstone.key(semester: semester, courseNo: courseNo))
            }
        }
        return keys
    }

    /// `then` runs once the add is queued, in the same task.
    func addCourse(
        semester: String, courseNo: String, then: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        let id = UUID()
        let key = CourseTombstone.key(semester: semester, courseNo: courseNo)
        let stamp = Date()
        addsEnqueuing[id] = key
        addTimes[key] = stamp
        return Task {
            await outbox.enqueue(.courseAdd(semester: semester, courseNo: courseNo, stamp: stamp))
            addsEnqueuing[id] = nil
            await then()
        }
    }

    func noteCourseAddLanded(_ key: String) {
        addTimes[key] = Date()
    }

    /// Sampling the outbox misses an add that starts while it is read, so an add started or
    /// landed since `date` counts by its time.
    func courseAddKeys(unlandedAt date: Date) async -> Set<String> {
        var keys = Set(addsEnqueuing.values)
        for entry in await outbox.snapshot() + outbox.parkedSnapshot() {
            if case .courseAdd(let semester, let courseNo, _) = entry.op {
                keys.insert(CourseTombstone.key(semester: semester, courseNo: courseNo))
            }
        }
        return keys.union(addTimes.filter { $0.value >= date }.keys)
    }

    /// Drops the course adds and deletes made here before another device's course reset at
    /// `resetAt`, the server's `courses_reset_at`, and returns the keys of the deletes. One made
    /// after the reset, or within the skew margin of it, stays.
    func dropCourseEdits(madeBeforeReset resetAt: Date) async -> Set<String> {
        let cutoff = resetAt.addingTimeInterval(-CloudSyncCoordinator.clockSkewMargin)
        let dropped = await discard(madeBefore: ["ca": cutoff, "cd": cutoff])
        return Self.courseKeys(of: dropped.filter { op in
            if case .courseDelete = op { return true }
            return false
        })
    }

    /// Drops the deletes queued before `cutoff`, the time of the re-add or reset, which a caller
    /// takes before its task hop so a hide made after the action is kept.
    func discardCourseDeletes(semester: String?, courseKeys: Set<String>?, madeBefore cutoff: Date) async {
        let serverPrefix = CourseTombstone.serverKey(of: "")
        let scopes = courseKeys.map { keys in
            keys.compactMap { key -> String? in
                let local = String(key.dropFirst(serverPrefix.count))
                guard key.hasPrefix(serverPrefix),
                      semester == nil || CourseTombstone.parts(of: local)?.semester == semester else { return nil }
                return "cd|" + local
            }
        } ?? [semester.map { "cd|\($0)" } ?? "cd"]
        await discard(madeBefore: Dictionary(uniqueKeysWithValues: scopes.map { ($0, cutoff) }))
    }

    private nonisolated static func courseKeys(of ops: [SyncOp]) -> Set<String> {
        Set(ops.compactMap { op -> String? in
            switch op {
            case .courseAdd(let semester, let courseNo, _), .courseDelete(let semester, let courseNo, _):
                return CourseTombstone.key(semester: semester, courseNo: courseNo)
            case .courseOverride, .assignmentOverride, .courseIgnore:
                return nil
            }
        })
    }

    /// Nothing a discard or an add recorded carries over once the queue is cleared.
    func forgetDiscards() {
        cutoffs = [:]
        addTimes = [:]
    }

    /// An edit of the same field queued after `op`, which a value the backend kept must not undo.
    func hasNewerEdit(than op: SyncOp) async -> Bool {
        let key = op.dedupKey
        let queued = await outbox.snapshot().map(\.op) + outbox.parkedSnapshot().map(\.op)
            + overridesEnqueuing.values
        return queued.contains { $0.dedupKey == key && $0.stamp > op.stamp }
    }
}
