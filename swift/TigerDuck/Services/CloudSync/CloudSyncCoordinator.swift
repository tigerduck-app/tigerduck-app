import Defaults
import Foundation
import Observation
import os
#if canImport(UIKit)
import UIKit
#endif

nonisolated enum CloudSyncState: Equatable, Sendable {
    case disabled
    case enabling(step: String)
    case active
}

@MainActor
@Observable
final class CloudSyncCoordinator {

    enum Tunables {
        static let tickInterval: TimeInterval = 5 * 60
    }

    private(set) var state: CloudSyncState = .disabled

    private(set) static weak var shared: CloudSyncCoordinator?

    static func registerShared(_ coordinator: CloudSyncCoordinator) {
        shared = coordinator
    }

    @ObservationIgnored private let pushCoordinator: PushCoordinator
    @ObservationIgnored let outbox: SyncOutbox
    @ObservationIgnored private let syncsAssignmentMarks: @Sendable () -> Bool
    @ObservationIgnored private let syncsCourseIgnores: @Sendable () -> Bool
    @ObservationIgnored private let addedCourseUpload: @MainActor (_ semester: String, _ courseNo: String)
        -> PushAPI.CourseUploadRequest?
    @ObservationIgnored private let uploadsCourses: @MainActor () -> Bool
    @ObservationIgnored private let isProtectedDataAvailable: @MainActor () -> Bool
    @ObservationIgnored private let loginGeneration: @MainActor () -> Int
    @ObservationIgnored private let logger = Logger(
        subsystem: "org.ntust.app.TigerDuck", category: "CloudSync.Coordinator")

    @ObservationIgnored private var tickInFlight = false
    @ObservationIgnored private var tickAskedDuringFlight = false
    @ObservationIgnored var started = false
    @ObservationIgnored private var courseOverridesEnqueuing: [UUID: SyncOp] = [:]
    @ObservationIgnored private var courseOverrideEdits = 0
    @ObservationIgnored private var lastColorEdit: [String: Int] = [:]
    @ObservationIgnored private var lastNameEdit: [String: Int] = [:]
    @ObservationIgnored private var courseAddsEnqueuing: [UUID: String] = [:]
    @ObservationIgnored private var courseAddsLanded: [String: Date] = [:]

    @ObservationIgnored var notificationTokens: [NSObjectProtocol] = []
    @ObservationIgnored var tickTimer: Timer?

    init(
        pushCoordinator: PushCoordinator,
        outbox: SyncOutbox = SyncOutbox(),
        isEnabled: Bool = Defaults[.cloudSyncEnabled],
        syncsAssignmentMarks: @escaping @Sendable () -> Bool = {
            CloudSyncCoordinator.sendsAssignmentMarks(
                assignments: Defaults[.syncAssignments],
                pendingChecks: Defaults[.pendingConflictCategories]
            )
        },
        syncsCourseIgnores: @escaping @Sendable () -> Bool = {
            CloudSyncCoordinator.sendsCourseIgnores(
                assignments: Defaults[.syncAssignments],
                courses: Defaults[.syncCourses],
                pendingChecks: Defaults[.pendingConflictCategories]
            )
        },
        addedCourseUpload: @escaping @MainActor (_ semester: String, _ courseNo: String)
            -> PushAPI.CourseUploadRequest? = { _, _ in nil },
        uploadsCourses: @escaping @MainActor () -> Bool = { false },
        isProtectedDataAvailable: @escaping @MainActor () -> Bool = {
            #if canImport(UIKit)
            UIApplication.shared.isProtectedDataAvailable
            #else
            true
            #endif
        },
        loginGeneration: @escaping @MainActor () -> Int = { 0 }
    ) {
        self.pushCoordinator = pushCoordinator
        self.outbox = outbox
        self.isProtectedDataAvailable = isProtectedDataAvailable
        self.loginGeneration = loginGeneration
        self.syncsAssignmentMarks = syncsAssignmentMarks
        self.syncsCourseIgnores = syncsCourseIgnores
        self.addedCourseUpload = addedCourseUpload
        self.uploadsCourses = uploadsCourses

        if isEnabled {
            state = .active
        }
    }

    nonisolated static func sendsAssignmentMarks(assignments: Bool, pendingChecks: Set<String>) -> Bool {
        assignments && !pendingChecks.contains("assignments")
    }

    nonisolated static func sendsCourseIgnores(assignments: Bool, courses: Bool, pendingChecks: Set<String>) -> Bool {
        assignments && courses && !pendingChecks.contains("assignments")
    }

    @ObservationIgnored private var lifecycleTask: Task<Void, Never>?

    func followPreference() {
        enqueueTransition { [weak self] in
            await self?.matchPreference()
        }
    }

    func settleForSignOut() async {
        await enqueueTransition { [weak self] in
            await self?.matchPreference()
            await self?.outbox.clearAll()
        }.value
    }

    private func matchPreference() async {
        switch (Defaults[.cloudSyncEnabled], state) {
        case (true, .disabled):
            await performEnable()
        case (false, .active), (false, .enabling):
            await performDisable()
        default:
            break
        }
    }

    @discardableResult
    private func enqueueTransition(
        _ transition: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        let previous = lifecycleTask
        let task = Task { @MainActor in
            await previous?.value
            await transition()
        }
        lifecycleTask = task
        return task
    }

    private func performEnable() async {
        if case .enabling = state { return }
        state = .enabling(step: "register")

        pushCoordinator.enable()
        await pushCoordinator.registration.updateCloudSyncEnabled(true)
    // MARK: - Following the preference

    /// Transitions run multi-step async work with side effects (push enable,
    /// the preference PATCH, outbox clear). MainActor isolation does NOT
    /// serialize across await suspension points, so an interleaved
    /// enable/disable could leave the coordinator active while the push
    /// stack is disabled. Every transition is chained through this task so
    /// they run to completion one at a time.

        state = .active
        start()
        await syncTick()
    }

    private func performDisable() async {
        stop()

        await pushCoordinator.registration.updateCloudSyncEnabled(false)

        await outbox.clearAll()

        state = .disabled
    }

    func syncTick() async {
        guard state == .active else { return }
        guard !tickInFlight else {
            tickAskedDuringFlight = true
            return
        }
        tickInFlight = true
        defer { tickInFlight = false }
        repeat {
            tickAskedDuringFlight = false
            await drainOnce()
        } while tickAskedDuringFlight && state == .active
    }

    private func drainOnce() async {
        let protectedDataAvailable = isProtectedDataAvailable()
        await outbox.loadOrGiveUp(protectedDataAvailable: protectedDataAvailable)
        guard await outbox.pendingCount() > 0 else { return }

        let syncsMarks = syncsAssignmentMarks
        let syncsIgnores = syncsCourseIgnores
        await outbox.drain(holding: { op in
            switch op {
            case .assignmentOverride: return !syncsMarks()
            case .courseIgnore: return !syncsIgnores()
            case .courseAdd: return !protectedDataAvailable
            case .courseOverride, .courseDelete: return false
            }
        }) { [weak self] op in
            guard let self else { throw CancellationError() }
            try await self.execute(op)
        }
    }

    func onRevisionChanged() async {
        await syncTick()
    }

    func onSyncTrigger() async {
        await syncTick()
    }

    @discardableResult
    func enqueueCourseColorOverride(moodleId: String, semester: String, colorHex: String) -> Task<Void, Never>? {
        guard state != .disabled else { return nil }
        return enqueueCourseOverride(.courseOverride(
            semester: semester, moodleId: moodleId,
            customName: nil, colorHex: colorHex, locale: nil, stamp: Date()))
    }

    @discardableResult
    func enqueueCourseNameOverride(
        moodleId: String, semester: String, customName: String, locale: String?
    ) -> Task<Void, Never>? {
        guard state != .disabled else { return nil }
        return enqueueCourseOverride(.courseOverride(
            semester: semester, moodleId: moodleId,
            customName: customName, colorHex: nil, locale: locale, stamp: Date()))
    }

    private func enqueueCourseOverride(_ op: SyncOp) -> Task<Void, Never> {
        if case .courseOverride(_, let moodleId, let customName, let colorHex, _, _) = op {
            courseOverrideEdits += 1
            if colorHex != nil { lastColorEdit[moodleId] = courseOverrideEdits }
            if customName != nil { lastNameEdit[moodleId] = courseOverrideEdits }
        }
        let id = UUID()
        courseOverridesEnqueuing[id] = op
        return Task {
            await outbox.enqueue(op)
            courseOverridesEnqueuing[id] = nil
        }
    }

    func enqueueAssignmentOverride(moodleCourseId: Int, moodleAssignmentId: Int, localStatus: String) async {
        guard state != .disabled else { return }
        let op = SyncOp.assignmentOverride(
            moodleCourseId: moodleCourseId,
            moodleAssignmentId: moodleAssignmentId,
            localStatus: localStatus, stamp: Date())
        await outbox.enqueue(op)
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
        if !courseOverridesEnqueuing.isEmpty || !courseAddsEnqueuing.isEmpty { return true }
        return await outbox.holdsEntries()
    }

    func pendingCourseOverrides() async -> (colors: Set<String>, names: Set<String>, edits: Int) {
        var pending: (colors: Set<String>, names: Set<String>, edits: Int) = ([], [], courseOverrideEdits)
        for op in await outbox.snapshot().map(\.op) + courseOverridesEnqueuing.values {
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
        await outbox.discard { op in
            switch op {
            case .assignmentOverride:
                return categories.contains("assignments")
            case .courseIgnore:
                return courseIgnores && categories.contains("assignments")
            case .courseOverride(_, _, let customName, let colorHex, _, _):
                return (colorHex != nil && categories.contains("course_colors"))
                    || (customName != nil && categories.contains("course_names"))
            case .courseAdd:
                return categories.contains("courses")
            case .courseDelete:
                return false
            }
        }
    }

    func enqueueCourseIgnore(semester: String, courseNo: String, moodleId: String, moodleCourseId: Int?, ignore: Bool?) async {
        guard state != .disabled else { return }
        await outbox.enqueue(.courseIgnore(
            semester: semester, courseNo: courseNo, moodleId: moodleId,
            moodleCourseId: moodleCourseId, ignore: ignore, stamp: Date()))
    }

    func discardCourseIgnores(semester: String? = nil, courseNo: String? = nil) async {
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

    func enqueueCourseDelete(semester: String, courseNo: String) async {
        guard state != .disabled else { return }
        await outbox.enqueue(.courseDelete(semester: semester, courseNo: courseNo, stamp: Date()))
    }

    func deleteCourse(semester: String, courseNo: String) async {
        await discardCourseIgnores(semester: semester, courseNo: courseNo)
        await enqueueCourseDelete(semester: semester, courseNo: courseNo)
        await syncTick()
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

    @discardableResult
    func addCourse(semester: String, courseNo: String) -> Task<Void, Never> {
        let id = UUID()
        courseAddsEnqueuing[id] = CourseTombstone.key(semester: semester, courseNo: courseNo)
        return Task {
            await outbox.enqueue(.courseAdd(semester: semester, courseNo: courseNo, stamp: Date()))
            courseAddsEnqueuing[id] = nil
            await syncTick()
        }
    }

    func courseAddKeys(unlandedAt date: Date) async -> Set<String> {
        var keys = Set(courseAddsEnqueuing.values)
        for entry in await outbox.snapshot() + outbox.parkedSnapshot() {
            if case .courseAdd(let semester, let courseNo, _) = entry.op {
                keys.insert(CourseTombstone.key(semester: semester, courseNo: courseNo))
            }
        }
        return keys.union(courseAddsLanded.filter { $0.value >= date }.keys)
    }

    func discardCourseDeletes(semester: String? = nil, courseKeys: Set<String>? = nil) async {
        await outbox.discard { op in
            guard case .courseDelete(let opSemester, let courseNo, _) = op else { return false }
            let key = CourseTombstone.serverKey(semester: opSemester, courseNo: courseNo)
            return (semester == nil || semester == opSemester) && (courseKeys?.contains(key) ?? true)
        }
    }

    func requeueParkedMarks() async {
        await outbox.requeueParked()
    }

    private func execute(_ op: ResolvedSyncOp) async throws {
        do {
            switch op {
            case .courseOverride(let courseId, let colorHex, let customName, let locale):
                _ = try await pushCoordinator.patchCourseOverride(
                    moodleId: courseId,
                    colorHex: colorHex,
                    customName: customName,
                    locale: locale)

            case .assignmentOverride(let assignmentId, let localStatus):
                try await pushCoordinator.patchAssignmentOverride(
                    moodleAssignmentId: String(assignmentId),
                    localStatus: localStatus)

            case .courseIgnore(let courseId, let moodleCourseId, let ignore):
                let response = try await pushCoordinator.patchCourseOverride(
                    moodleId: courseId,
                    ignoreAssignments: ignore,
                    moodleCourseId: moodleCourseId)
                guard response.ignoreAssignments != nil else { throw CourseIgnoreNotStoredError() }

            case .courseDelete(let courseKey):
                try await pushCoordinator.deleteCourse(courseKey: courseKey)

            case .courseAdd(let semester, let courseNo):
                guard isProtectedDataAvailable() else { throw CancellationError() }
                let generation = loginGeneration()
                guard let request = addedCourseUpload(semester, courseNo) else { return }
                guard try await pushCoordinator.uploadCoursesIfChanged(
                    request, semester: semester,
                    isCurrent: { [uploadsCourses, loginGeneration] in uploadsCourses() && loginGeneration() == generation }
                ) else { return }
                courseAddsLanded[CourseTombstone.key(semester: semester, courseNo: courseNo)] = Date()
            }
        } catch {
            if isUnauthorized(error) {
                throw SyncOutboxAuthError(statusCode: 401)
            }
            throw error
        }
    }

    func start() {
        guard !started else { return }
        started = true

        attachObservers()

        let timer = Timer.scheduledTimer(withTimeInterval: Tunables.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.syncTick()
            }
        }
        tickTimer = timer
    }

    func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        notificationTokens = []
        started = false
    }

    private func attachObservers() {
        let center = NotificationCenter.default

        func observe(_ name: Notification.Name, handler: @escaping @MainActor () -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler() }
            }
            notificationTokens.append(token)
        }

        #if canImport(UIKit)
        observe(UIApplication.didBecomeActiveNotification) { [weak self] in
            guard let self, self.state == .active else { return }
            self.scheduleTick()
        }
        #endif
    }

    func scheduleTick(after seconds: TimeInterval = 0) {
        Task { [weak self] in
            if seconds > 0 {
                try? await Task.sleep(for: .seconds(seconds))
            }
            await self?.syncTick()
        }
    }

    private func isUnauthorized(_ error: Error) -> Bool {
        if case PushAPIError.httpStatus(401, _) = error { return true }
        if case PushAPIError.notSignedIn = error { return true }
        return false
    }
}

nonisolated struct CourseIgnoreNotStoredError: Error {}
                // A backend without the setting answers 200 and drops it, so only an answer that
                // names it settles the op; anything else counts as a refusal.
