import Foundation

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

    func discardEdits(of categories: Set<String>, courseIgnores: Bool) async {
        var scopes = categories.intersection(["assignments", "course_colors", "course_names"])
        if categories.contains("courses") { scopes.insert("ca") }
        if courseIgnores && categories.contains("assignments") { scopes.insert("course_ignores") }
        overridesEnqueuing = overridesEnqueuing.filter { scopes.isDisjoint(with: $0.value.scopes) }
        if scopes.contains("ca") { addsEnqueuing = [:] }
        let now = Date()
        await discard(madeBefore: Dictionary(uniqueKeysWithValues: scopes.map { ($0, now) }))
    }

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

    func courseAddKeys(unlandedAt date: Date) async -> Set<String> {
        var keys = Set(addsEnqueuing.values)
        for entry in await outbox.snapshot() + outbox.parkedSnapshot() {
            if case .courseAdd(let semester, let courseNo, _) = entry.op {
                keys.insert(CourseTombstone.key(semester: semester, courseNo: courseNo))
            }
        }
        return keys.union(addTimes.filter { $0.value >= date }.keys)
    }

    func dropCourseEdits(madeBeforeReset resetAt: Date) async -> Set<String> {
        let cutoff = resetAt.addingTimeInterval(-CloudSyncCoordinator.clockSkewMargin)
        let dropped = await discard(madeBefore: ["ca": cutoff, "cd": cutoff])
        return Self.courseKeys(of: dropped.filter { op in
            if case .courseDelete = op { return true }
            return false
        })
    }

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

    func forgetDiscards() {
        cutoffs = [:]
        addTimes = [:]
    }

    func hasNewerEdit(than op: SyncOp) async -> Bool {
        let key = op.dedupKey
        let queued = await outbox.snapshot().map(\.op) + outbox.parkedSnapshot().map(\.op)
            + overridesEnqueuing.values
        return queued.contains { $0.dedupKey == key && $0.stamp > op.stamp }
    }
}
