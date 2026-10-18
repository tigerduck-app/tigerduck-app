import Defaults
import Foundation
import Observation
import os
#if canImport(UIKit)
import UIKit
#endif

// MARK: - State

nonisolated enum CloudSyncState: Equatable, Sendable {
    case disabled
    case enabling(step: String)
    case active
}

// MARK: - CloudSyncCoordinator

/// Owns the cloud-sync lifecycle: enable/disable state machine,
/// periodic sync ticks, local-edit observers that feed the outbox,
/// and outbox drain with retry. Delegates actual API calls to the
/// existing PushCoordinator.
///
/// Architecture by xinshoutw — adapted for the v3-backend branch.
@MainActor
@Observable
final class CloudSyncCoordinator {

    // MARK: Tunables

    enum Tunables {
        static let tickInterval: TimeInterval = 5 * 60
    }

    // MARK: Observable state

    private(set) var state: CloudSyncState = .disabled

    // MARK: Shared instance

    private(set) static weak var shared: CloudSyncCoordinator?

    static func registerShared(_ coordinator: CloudSyncCoordinator) {
        shared = coordinator
    }

    // MARK: Dependencies

    @ObservationIgnored private let pushCoordinator: PushCoordinator
    @ObservationIgnored let outbox: SyncOutbox
    /// `sendsAssignmentMarks`, read before each mark goes out. A mark queued while it is false
    /// waits.
    @ObservationIgnored private let syncsAssignmentMarks: @Sendable () -> Bool
    /// `sendsCourseIgnores`, read before each course's ignore setting goes out. A setting queued
    /// while it is false waits.
    @ObservationIgnored private let syncsCourseIgnores: @Sendable () -> Bool
    /// The upload of a course added here, as the device holds it when its add goes, or nil once
    /// it is gone or hidden, which drops the add unsent (`AppState.addedCourseUpload`).
    @ObservationIgnored private let addedCourseUpload: @MainActor (_ semester: String, _ courseNo: String)
        -> PushAPI.CourseUploadRequest?
    /// Whether this device may upload its course list (`CourseUploadPolicy.uploadsCourses`), read
    /// right before a course add goes: one that comes due with it false is dropped unsent.
    @ObservationIgnored private let uploadsCourses: @MainActor () -> Bool
    @ObservationIgnored private let logger = Logger(
        subsystem: "org.ntust.app.TigerDuck", category: "CloudSync.Coordinator")

    // MARK: Internal state

    @ObservationIgnored private var tickInFlight = false
    /// A tick asked for while one is running, which runs once that one ends.
    @ObservationIgnored private var tickAskedDuringFlight = false
    @ObservationIgnored var started = false
    /// Colour and name edits on their way into the outbox, which `pendingCourseOverrides` counts.
    @ObservationIgnored private var courseOverridesEnqueuing: [UUID: SyncOp] = [:]
    /// Moved by each colour or name edit queued here. `lastColorEdit` and `lastNameEdit` keep its
    /// value at each course's last colour edit and last name edit, by Moodle id.
    @ObservationIgnored private var courseOverrideEdits = 0
    @ObservationIgnored private var lastColorEdit: [String: Int] = [:]
    @ObservationIgnored private var lastNameEdit: [String: Int] = [:]
    /// Course adds on their way into the outbox, by `CourseTombstone` key.
    @ObservationIgnored private var courseAddsEnqueuing: [UUID: String] = [:]
    /// When each course added here last landed, by `CourseTombstone` key.
    @ObservationIgnored private var courseAddsLanded: [String: Date] = [:]

    // Observer plumbing
    @ObservationIgnored var notificationTokens: [NSObjectProtocol] = []
    @ObservationIgnored var tickTimer: Timer?

    // MARK: Init

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
        uploadsCourses: @escaping @MainActor () -> Bool = { false }
    ) {
        self.pushCoordinator = pushCoordinator
        self.outbox = outbox
        self.syncsAssignmentMarks = syncsAssignmentMarks
        self.syncsCourseIgnores = syncsCourseIgnores
        self.addedCourseUpload = addedCourseUpload
        self.uploadsCourses = uploadsCourses

        if isEnabled {
            state = .active
        }
    }

    /// Whether a mark may go out: with the Assignments switch on, and not while its re-enable check
    /// is pending, which may take the server's marks over the ones queued here.
    nonisolated static func sendsAssignmentMarks(assignments: Bool, pendingChecks: Set<String>) -> Bool {
        assignments && !pendingChecks.contains("assignments")
    }

    /// Whether a course's ignore setting may go out: with the Assignments and Courses switches on,
    /// as the server drops the setting with the course rows once no device syncs courses, and not
    /// while the re-enabled Assignments switch's check is pending, which may take the server's
    /// settings over the ones queued here.
    nonisolated static func sendsCourseIgnores(assignments: Bool, courses: Bool, pendingChecks: Set<String>) -> Bool {
        assignments && courses && !pendingChecks.contains("assignments")
    }

    // MARK: - Following the preference

    /// Transitions run multi-step async work with side effects (push enable,
    /// the preference PATCH, outbox clear). MainActor isolation does NOT
    /// serialize across await suspension points, so an interleaved
    /// enable/disable could leave the coordinator active while the push
    /// stack is disabled. Every transition is chained through this task so
    /// they run to completion one at a time.
    @ObservationIgnored private var lifecycleTask: Task<Void, Never>?

    /// Brings the lifecycle in line with the Sync course information preference.
    /// `AppState` calls this on every change to it, whichever writer made it.
    ///
    /// Queued behind any transition still running, and the preference is read
    /// when its turn comes rather than when it was asked for, so a burst of
    /// toggles lands on the last one. This coordinator never writes the
    /// preference: it follows it, and a write from here would come straight
    /// back through `AppState` as another change.
    func followPreference() {
        enqueueTransition { [weak self] in
            await self?.matchPreference()
        }
    }

    /// Sign-out, which has just turned the preference off: waits for the
    /// lifecycle to follow it, and empties the outbox even when sync was
    /// already off, so none of the departing account's queued edits reach
    /// whoever signs in next.
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

    // MARK: - Enable

    private func performEnable() async {
        if case .enabling = state { return }
        state = .enabling(step: "register")

        pushCoordinator.enable()
        await pushCoordinator.registration.updateCloudSyncEnabled(true)

        state = .active
        // Start even when the PATCH above failed (e.g. enabled while
        // offline): the timer and observers are how sync self-heals, and
        // a relaunch would start them in this state anyway.
        start()
        // Flush any edits queued during the .enabling window now that
        // we're active (their scheduleTick fired while draining was gated).
        await syncTick()
    }

    // MARK: - Disable

    private func performDisable() async {
        stop()

        // Keep the push stack up, registered with cloud_sync_enabled=false: bulletins and
        // operator pushes are not gated on the flag, and a relaunch restores the stack anyway.
        // Live Activity is unavailable with sync off; the schedule this device uploads goes empty.
        await pushCoordinator.registration.updateCloudSyncEnabled(false)

        await outbox.clearAll()

        state = .disabled
    }

    // MARK: - Sync tick

    /// Drains the outbox. Pulls belong to `AppState.syncOverridesFromBackend`,
    /// which applies what it fetches; a tick has no use for a snapshot.
    func syncTick() async {
        guard state == .active else { return }
        // An op queued while a drain is out is not in that drain, so it gets one more pass.
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
        #if canImport(UIKit)
        let protectedDataAvailable = UIApplication.shared.isProtectedDataAvailable
        #else
        let protectedDataAvailable = true
        #endif
        await outbox.loadOrGiveUp(protectedDataAvailable: protectedDataAvailable)
        guard await outbox.pendingCount() > 0 else { return }

        let syncsMarks = syncsAssignmentMarks
        let syncsIgnores = syncsCourseIgnores
        await outbox.drain(holding: { op in
            switch op {
            case .assignmentOverride: return !syncsMarks()
            case .courseIgnore: return !syncsIgnores()
            case .courseOverride, .courseDelete, .courseAdd: return false
            }
        }) { [weak self] op in
            guard let self else { throw CancellationError() }
            try await self.execute(op)
        }
    }

    /// Called by the revision poller when the server revision is ahead,
    /// after `AppState.syncChangesSinceLastRevision()` has applied what moved.
    func onRevisionChanged() async {
        await syncTick()
    }

    /// Called when a sync_trigger push notification arrives, after the pull.
    func onSyncTrigger() async {
        await syncTick()
    }

    // MARK: - Enqueue helpers

    @discardableResult
    func enqueueCourseColorOverride(moodleId: String, semester: String, colorHex: String) -> Task<Void, Never>? {
        // Accept edits during the enable() window (.enabling) too: the op
        // queues durably in the outbox and drains once state flips to .active.
        // Gating on == .active would silently drop them.
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

    /// The task ends once the edit is in the outbox.
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

    /// Awaitable so callers can key "op is durably queued" transitions
    /// (e.g. AppState's pending-override conflict guard) off completion.
    func enqueueAssignmentOverride(moodleCourseId: Int, moodleAssignmentId: Int, localStatus: String) async {
        guard state != .disabled else { return }
        let op = SyncOp.assignmentOverride(
            moodleCourseId: moodleCourseId,
            moodleAssignmentId: moodleAssignmentId,
            localStatus: localStatus, stamp: Date())
        await outbox.enqueue(op)
    }

    /// Moodle assignment ids (as strings) with a queued or parked outbox op
    /// that has not yet reached the server. Conflict detection must treat
    /// these as local-pending rather than cross-device conflicts.
    func pendingAssignmentOverrideIds() async -> Set<String> {
        var ids = Set<String>()
        for entry in await outbox.snapshot() + outbox.parkedSnapshot() {
            if case .assignmentOverride(_, let moodleAssignmentId, _, _) = entry.op {
                ids.insert(String(moodleAssignmentId))
            }
        }
        return ids
    }

    /// Whether edits wait to go up: on their way into the outbox, or queued or parked in it. Those
    /// on their way in are read first and the outbox in one call, so an edit that reaches the outbox
    /// meanwhile is seen there.
    func holdsUnsentEdits() async -> Bool {
        if !courseOverridesEnqueuing.isEmpty || !courseAddsEnqueuing.isEmpty { return true }
        return await outbox.holdsEntries()
    }

    /// The Moodle ids of the courses with a colour or a name edit queued here, which the server
    /// may not have yet, and `edits`, the `courseOverrideEdits` count read before them. A full
    /// sync leaves those as they are here, as it leaves queued marks (`courseOverridesToHold`).
    func pendingCourseOverrides() async -> (colors: Set<String>, names: Set<String>, edits: Int) {
        var pending: (colors: Set<String>, names: Set<String>, edits: Int) = ([], [], courseOverrideEdits)
        // The edits on their way in are read after the snapshot, or one could land between the two.
        for op in await outbox.snapshot().map(\.op) + courseOverridesEnqueuing.values {
            guard case .courseOverride(_, let moodleId, let customName, let colorHex, _, _) = op else { continue }
            if colorHex != nil { pending.colors.insert(moodleId) }
            if customName != nil { pending.names.insert(moodleId) }
        }
        return pending
    }

    /// The Moodle ids of the courses with a colour or a name edit queued after `reading`, a value of
    /// `courseOverrideEdits`.
    func courseOverrides(queuedAfter reading: Int) -> (colors: Set<String>, names: Set<String>) {
        (Set(lastColorEdit.filter { $0.value > reading }.keys), Set(lastNameEdit.filter { $0.value > reading }.keys))
    }

    /// What a full sync leaves as it is here: what `pending` listed before its fetch, and each
    /// colour or name edited since, which an edit queued and sent while the fetch was out would
    /// otherwise escape, as it is in no sample.
    func courseOverridesToHold(
        since pending: (colors: Set<String>, names: Set<String>, edits: Int)
    ) -> (colors: Set<String>, names: Set<String>) {
        let edited = courseOverrides(queuedAfter: pending.edits)
        return (pending.colors.union(edited.colors), pending.names.union(edited.names))
    }

    /// For Use Server in the re-enable dialog, which takes the server's data of `categories` over
    /// the edits of them still on their way up: the course adds for "courses", the marks for
    /// "assignments", with the course settings when its check compared them (`courseIgnores`), and
    /// the colours and the names for "course_colors" and "course_names".
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

    /// Awaitable for the same reason as `enqueueAssignmentOverride`.
    func enqueueCourseIgnore(semester: String, courseNo: String, moodleId: String, moodleCourseId: Int?, ignore: Bool?) async {
        guard state != .disabled else { return }
        await outbox.enqueue(.courseIgnore(
            semester: semester, courseNo: courseNo, moodleId: moodleId,
            moodleCourseId: moodleCourseId, ignore: ignore, stamp: Date()))
    }

    /// Drops the course settings still on their way up: all of them for Use Server, which takes
    /// the server's over them, or `semester`'s or one course's for a reset or a delete, after which
    /// the server has no row to take them.
    func discardCourseIgnores(semester: String? = nil, courseNo: String? = nil) async {
        await outbox.discard { op in
            guard case .courseIgnore(let opSemester, let opCourseNo, _, _, _, _) = op else { return false }
            return (semester == nil || semester == opSemester) && (courseNo == nil || courseNo == opCourseNo)
        }
    }

    /// `CourseTombstone` keys of the courses whose ignore setting is queued or parked, not yet on
    /// the server, which a pull leaves as they are here. A numeric id sent alone changes no setting.
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

    /// Deletes a course hidden here from the server through the outbox. Its settings still queued
    /// go first: the server drops them with the row, so their PATCH would 404.
    func deleteCourse(semester: String, courseNo: String) async {
        await discardCourseIgnores(semester: semester, courseNo: courseNo)
        await enqueueCourseDelete(semester: semester, courseNo: courseNo)
        await syncTick()
    }

    /// Runs `fetch` and returns what it fetched with the keys of the course deletes queued before or
    /// after it (`pendingCourseDeleteKeys`): one that lands meanwhile leaves the outbox, but the
    /// snapshot fetched may still list its course.
    func courseDeletes<Fetched>(
        around fetch: () async throws -> Fetched
    ) async rethrows -> (fetched: Fetched, deleting: Set<String>) {
        let before = await pendingCourseDeleteKeys()
        let fetched = try await fetch()
        return (fetched, before.union(await pendingCourseDeleteKeys()))
    }

    /// `CourseTombstone` keys of the courses whose delete is queued, which the server may still
    /// list: a full sync keeps them hidden here.
    func pendingCourseDeleteKeys() async -> Set<String> {
        var keys = Set<String>()
        for entry in await outbox.snapshot() {
            if case .courseDelete(let semester, let courseNo, _) = entry.op {
                keys.insert(CourseTombstone.key(semester: semester, courseNo: courseNo))
            }
        }
        return keys
    }

    /// Queues the upload of a course added here and sends it; the outbox keeps it until it lands.
    /// Queued in every state, as `AppState` sends an add only with sync on: one made while this is
    /// still enabling goes once it is active. The task ends after the outbox has had a try at it.
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

    /// `CourseTombstone` keys of the courses added here whose upload had not landed by `date`: on
    /// their way into the outbox, queued or parked in it, or landed since. A snapshot fetched at
    /// `date` can predate each, so a full sync keeps them.
    func courseAddKeys(unlandedAt date: Date) async -> Set<String> {
        // On their way in first: an add that reaches the outbox meanwhile is in the snapshot.
        var keys = Set(courseAddsEnqueuing.values)
        for entry in await outbox.snapshot() + outbox.parkedSnapshot() {
            if case .courseAdd(let semester, let courseNo, _) = entry.op {
                keys.insert(CourseTombstone.key(semester: semester, courseNo: courseNo))
            }
        }
        return keys.union(courseAddsLanded.filter { $0.value >= date }.keys)
    }

    /// Drops the course deletes still queued: every one, or `semester`'s, for a reset, which
    /// deletes the courses itself and shows them again here, and those of the courses `courseKeys`
    /// names, which were added back here.
    func discardCourseDeletes(semester: String? = nil, courseKeys: Set<String>? = nil) async {
        await outbox.discard { op in
            guard case .courseDelete(let opSemester, let courseNo, _) = op else { return false }
            let key = CourseTombstone.serverKey(semester: opSemester, courseNo: courseNo)
            return (semester == nil || semester == opSemester) && (courseKeys?.contains(key) ?? true)
        }
    }

    /// Gives each mark the server kept refusing one more try. Called by every full sync, and by
    /// each poll the change feed settles without one.
    func requeueParkedMarks() async {
        await outbox.requeueParked()
    }

    // MARK: - Execute resolved op

    /// 401s are rethrown as `SyncOutboxAuthError` so the drain aborts and
    /// retains the queue without burning retry attempts — the token layer
    /// refreshes the JWT, and a later tick delivers the ops. So is a request
    /// that was not sent for want of a session.
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
                // A backend without the setting answers 200 and drops it, so only an answer that
                // names it settles the op; anything else counts as a refusal.
                guard response.ignoreAssignments != nil else { throw CourseIgnoreNotStoredError() }

            case .courseDelete(let courseKey):
                try await pushCoordinator.deleteCourse(courseKey: courseKey)

            case .courseAdd(let semester, let courseNo):
                guard let request = addedCourseUpload(semester, courseNo) else { return }
                // In the term's upload chain, so an edit or a refresh queued after it lands after it.
                guard try await pushCoordinator.uploadCoursesIfChanged(
                    request, semester: semester, isCurrent: uploadsCourses
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

    // MARK: - Observers

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

    // MARK: - Helpers

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

/// A course setting the backend answered without storing: one that predates the setting.
nonisolated struct CourseIgnoreNotStoredError: Error {}
