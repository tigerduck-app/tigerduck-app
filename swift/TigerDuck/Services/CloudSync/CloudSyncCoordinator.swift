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
    @ObservationIgnored private let logger = Logger(
        subsystem: "org.ntust.app.TigerDuck", category: "CloudSync.Coordinator")

    // MARK: Internal state

    @ObservationIgnored private var tickInFlight = false
    @ObservationIgnored var started = false

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
        }
    ) {
        self.pushCoordinator = pushCoordinator
        self.outbox = outbox
        self.syncsAssignmentMarks = syncsAssignmentMarks
        self.syncsCourseIgnores = syncsCourseIgnores

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
        guard state == .active, !tickInFlight else { return }
        tickInFlight = true
        defer { tickInFlight = false }

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
            case .courseOverride: return false
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

    func enqueueCourseColorOverride(moodleId: String, semester: String, colorHex: String) {
        // Accept edits during the enable() window (.enabling) too: the op
        // queues durably in the outbox and drains once state flips to .active.
        // Gating on == .active would silently drop them.
        guard state != .disabled else { return }
        let op = SyncOp.courseOverride(
            semester: semester, moodleId: moodleId,
            customName: nil, colorHex: colorHex, locale: nil, stamp: Date())
        Task { await outbox.enqueue(op) }
    }

    func enqueueCourseNameOverride(moodleId: String, semester: String, customName: String, locale: String?) {
        guard state != .disabled else { return }
        let op = SyncOp.courseOverride(
            semester: semester, moodleId: moodleId,
            customName: customName, colorHex: nil, locale: locale, stamp: Date())
        Task { await outbox.enqueue(op) }
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

    /// For the re-enabled Assignments switch's Use Server, which takes the server's marks over the
    /// ones still on their way up.
    func discardAssignmentOverrides() async {
        await outbox.discard { op in
            if case .assignmentOverride = op { return true }
            return false
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
