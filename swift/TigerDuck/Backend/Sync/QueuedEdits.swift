import Foundation

@MainActor
final class QueuedEdits {
    private let outbox: SyncOutbox
    private let clock: SyncClock
    private var overridesEnqueuing: [UUID: SyncOp] = [:]
    private(set) var overrideEdits = 0
    private var lastColorEdit: [String: Int] = [:]
    private var lastNameEdit: [String: Int] = [:]
    private var addsEnqueuing: [UUID: String] = [:]
    private var addStartedOrLandedAt: [String: Date] = [:]
    private(set) var cutoffs = DiscardCutoffs()

    init(outbox: SyncOutbox, clock: SyncClock) {
        self.outbox = outbox
        self.clock = clock
    }

    func enqueueOverride(for signIn: SignIn, stamping makeOp: (Date) -> SyncOp) -> Task<Void, Never> {
        let era = clock.era
        let op = makeOp(clock.stamp())
        if case .courseOverride(_, let moodleId, let customName, let colorHex, _, _) = op {
            overrideEdits += 1
            if colorHex != nil { lastColorEdit[moodleId] = overrideEdits }
            if customName != nil { lastNameEdit[moodleId] = overrideEdits }
        }
        let id = UUID()
        overridesEnqueuing[id] = op
        return Task {
            await outbox.enqueue(op, takenIn: era, for: signIn)
            overridesEnqueuing[id] = nil
        }
    }

    func editCountAtLastColorEdit(of identity: String) -> Int {
        lastColorEdit[identity, default: 0]
    }

    var marksAndIgnoresEnqueuing: Set<String> {
        Set(overridesEnqueuing.values.compactMap { op -> String? in
            switch op {
            case .assignmentOverride(_, let moodleAssignmentId, _, _):
                return String(moodleAssignmentId)
            case .courseIgnore(let semester, let courseNo, _, _, .some, _):
                return CourseTombstone.key(semester: semester, courseNo: courseNo)
            case .courseIgnore, .courseOverride, .courseDelete, .courseAdd:
                return nil
            }
        })
    }

    func pendingAssignmentOverrideIds() async -> Set<String> {
        Set(await unsentOps().compactMap { op -> String? in
            guard case .assignmentOverride(_, let moodleAssignmentId, _, _) = op else { return nil }
            return String(moodleAssignmentId)
        })
    }

    func holdsUnsentEdits() async -> Bool {
        if !overridesEnqueuing.isEmpty || !addsEnqueuing.isEmpty { return true }
        return await outbox.holdsEntries()
    }

    func pendingCourseOverrides() async -> (colors: Set<String>, names: Set<String>, edits: Int) {
        var pending: (colors: Set<String>, names: Set<String>, edits: Int) = ([], [], overrideEdits)
        for op in await unsentOps() {
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

    func discardEdits(of categories: Set<SyncCategory>, courseIgnores: Bool) async {
        let byCategory: [SyncCategory: DiscardScope] = [
            .assignments: .assignmentMarks, .courseColors: .courseColors, .courseNames: .courseNames,
            .courses: .allCourseAdds,
        ]
        var scopes = Set(categories.compactMap { byCategory[$0] })
        if courseIgnores && categories.contains(.assignments) { scopes.insert(.courseIgnores) }
        overridesEnqueuing = overridesEnqueuing.filter { scopes.isDisjoint(with: $0.value.discardScopes) }
        if scopes.contains(.allCourseAdds) { addsEnqueuing = [:] }
        let era = clock.era
        let now = clock.stamp()
        await discard(madeBefore: Dictionary(uniqueKeysWithValues: scopes.map { ($0, now) }), takenIn: era)
    }

    @discardableResult
    private func discard(madeBefore scopeCutoffs: [DiscardScope: Date], takenIn era: SyncClock.Era) async -> [SyncOp] {
        let next = clock.lowestNextStamp
        cutoffs.keep(scopeCutoffs.mapValues(era.current), notAfter: era.current(next))
        return await outbox.discard(madeBefore: scopeCutoffs, notAfter: next, takenIn: era)
    }

    func discardCourseIgnores(semester: String?, courseNo: String?) async {
        await outbox.discard { op in
            guard case .courseIgnore(let opSemester, let opCourseNo, _, _, _, _) = op else { return false }
            return (semester == nil || semester == opSemester) && (courseNo == nil || courseNo == opCourseNo)
        }
    }

    func pendingCourseIgnoreKeys() async -> Set<String> {
        Set(await unsentOps().compactMap { op -> String? in
            guard case .courseIgnore(let semester, let courseNo, _, _, .some, _) = op else { return nil }
            return CourseTombstone.key(semester: semester, courseNo: courseNo)
        })
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
        semester: String, courseNo: String, for signIn: SignIn,
        afterEnqueued: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        let id = UUID()
        let key = CourseTombstone.key(semester: semester, courseNo: courseNo)
        let era = clock.era
        let stamp = clock.stamp()
        addsEnqueuing[id] = key
        addStartedOrLandedAt[key] = stamp
        return Task {
            await outbox.enqueue(.courseAdd(semester: semester, courseNo: courseNo, stamp: stamp), takenIn: era, for: signIn)
            addsEnqueuing[id] = nil
            await afterEnqueued()
        }
    }

    func noteCourseAddLanded(_ key: String) {
        addStartedOrLandedAt[key] = clock.stamp()
    }

    func courseAddKeys(unlandedAt date: Date, takenIn era: SyncClock.Era) async -> Set<String> {
        var keys = Set(addsEnqueuing.values)
        for entry in await outbox.snapshot() + outbox.parkedSnapshot() {
            if case .courseAdd(let semester, let courseNo, _) = entry.op {
                keys.insert(CourseTombstone.key(semester: semester, courseNo: courseNo))
            }
        }
        let landingFrom = era.current(date)
        return keys.union(addStartedOrLandedAt.filter { $0.value >= landingFrom }.keys)
    }

    func dropCourseEdits(madeBeforeReset resetAt: Date) async -> Set<String> {
        let cutoff = resetAt.addingTimeInterval(-CloudSyncCoordinator.clockSkewMargin)
        let dropped = await discard(madeBefore: [.allCourseAdds: cutoff, .allCourseDeletes: cutoff], takenIn: clock.era)
        return Self.courseKeys(of: dropped.filter { op in
            if case .courseDelete = op { return true }
            return false
        })
    }

    func discardCourseDeletes(
        semester: String?, courseKeys: Set<String>?, madeBeforeAction cutoff: Date, takenIn era: SyncClock.Era
    ) async {
        let serverPrefix = CourseTombstone.serverKey(of: "")
        let scopes = courseKeys.map { keys in
            keys.compactMap { key -> DiscardScope? in
                let local = String(key.dropFirst(serverPrefix.count))
                guard key.hasPrefix(serverPrefix),
                      semester == nil || CourseTombstone.parts(of: local)?.semester == semester else { return nil }
                return .courseDelete(key: local)
            }
        } ?? [semester.map { .courseDeletes(term: $0) } ?? .allCourseDeletes]
        await discard(madeBefore: Dictionary(uniqueKeysWithValues: scopes.map { ($0, cutoff) }), takenIn: era)
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

    func restamp(after pullBack: SyncClock.PullBack) async {
        overridesEnqueuing = overridesEnqueuing.mapValues { $0.restamped(pullBack.restamped) }
        cutoffs = cutoffs.restamped(pullBack.restamped)
        addStartedOrLandedAt = addStartedOrLandedAt.mapValues(pullBack.restamped)
        await outbox.restamp(after: pullBack)
    }

    func forgetDiscards() {
        cutoffs = DiscardCutoffs()
        addStartedOrLandedAt = [:]
    }

    func hasNewerEdit(than op: SyncOp) async -> Bool {
        let key = op.dedupKey
        return await unsentOps().contains { $0.dedupKey == key && $0.stamp > op.stamp }
    }

    private func unsentOps() async -> [SyncOp] {
        let enqueuingBeforeTheRead = Array(overridesEnqueuing.values)
        let queuedOrParked = await outbox.queuedAndParked().map(\.op)
        return enqueuingBeforeTheRead + queuedOrParked + overridesEnqueuing.values
    }
}
