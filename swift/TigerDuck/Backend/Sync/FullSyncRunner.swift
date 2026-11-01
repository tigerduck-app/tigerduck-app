import Defaults
import Foundation
import os
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class FullSyncRunner {
    let gate = FullSyncGate()
    private unowned let app: AppEnvironment

    init(app: AppEnvironment) {
        self.app = app
    }

    static let reconcilers: [any CategoryReconciler.Type] = [
        AssignmentMarksReconciler.self,
        CourseIgnoresReconciler.self,
        CourseOverridesReconciler.self,
        HolidayOverridesReconciler.self,
        CourseRosterReconciler.self,
    ]

    @discardableResult
    func sync(followUpIfBusy: Bool = false) async -> FullSyncOutcome {
        guard Defaults[.cloudSyncEnabled] else { return .skipped }
        #if os(iOS)
        // A sync trigger can launch the app behind the lock screen, where the local marks,
        // courses and colours cannot be opened and read as empty, and a sync would write the
        // server's view over them.
        guard UIApplication.shared.isProtectedDataAvailable else { return .skipped }
        #endif
        if gate.isRunning {
            AppLogger.sync.info("[syncOverrides] already in flight, follow-up: \(followUpIfBusy, privacy: .public)")
        }
        return await gate.run(followUp: followUpIfBusy, mayFollow: { Defaults[.cloudSyncEnabled] }) {
            await self.run()
        }
    }

    nonisolated static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    func retryUnsentEdits(for signIn: SignIn) async {
        app.holidays.retryUnacknowledged(for: signIn)
        #if os(iOS)
        app.notificationSettings.retryUnacknowledged()
        #endif
        await app.cloudSyncCoordinator.requeueParkedMarks()
    }

    nonisolated static func uploadsLocalMarksAsFirstSync(
        syncedBefore: Bool,
        serverHasMarks: Bool,
        localHasMarks: Bool
    ) -> Bool {
        !syncedBefore && !serverHasMarks && localHasMarks
    }

    /// A backend timestamp: Python `isoformat()`, which has microseconds unless they are zero.
    static func backendDate(_ value: Any?) -> Date? {
        guard let raw = value as? String else { return nil }
        return TigerDuckDateFormatters.withFractional.date(from: raw)
            ?? TigerDuckDateFormatters.withoutFractional.date(from: raw)
    }

    nonisolated static func fullSyncMayWrite(
        signedOutSince: Bool, cloudSyncEnabled: Bool, protectedDataAvailable: Bool
    ) -> Bool {
        !signedOutSince && cloudSyncEnabled && protectedDataAvailable
    }

    func mayWrite(for signIn: SignIn) -> Bool {
        #if os(iOS)
        let protectedDataAvailable = UIApplication.shared.isProtectedDataAvailable
        #else
        let protectedDataAvailable = true
        #endif
        return Self.fullSyncMayWrite(
            signedOutSince: !signIn.isCurrent,
            cloudSyncEnabled: Defaults[.cloudSyncEnabled],
            protectedDataAvailable: protectedDataAvailable
        )
    }

    func requireMayWrite(for signIn: SignIn) throws {
        guard mayWrite(for: signIn) else { throw FullSyncAbandoned() }
    }

    func settleQueuedCourseEdits(
        deleting: Set<String>, reset: (apply: Bool, remember: Date), for signIn: SignIn
    ) async throws -> Set<String> {
        guard reset.apply else { return deleting }
        let dropped = try await CourseReset.apply(
            at: reset.remember, courses: .shared, on: app.cloudSyncCoordinator, for: signIn,
            mayWrite: { self.mayWrite(for: signIn) }
        )
        SyncProgress.noteCoursesReset(reset.remember, for: signIn)
        app.localEdits.setRecentCourseDeletions([:], for: signIn)
        AppLogger.sync.info("[sync] courses reset detected (reset=\(String(describing: reset.remember), privacy: .public)), wiped local state")
        return deleting.subtracting(dropped)
    }

    private func run() async -> FullSyncOutcome {
        await app.authService.session.withSignIn { await run(for: $0) }
    }

    private func run(for signIn: SignIn) async -> FullSyncOutcome {
        await app.authService.ensureBackendSignedIn()
        guard await app.authTokenManager.isLoggedIn, mayWrite(for: signIn) else { return .skipped }
        await retryUnsentEdits(for: signIn)
        do {
            #if DEBUG
            try await ServerFailureSimulator.shared.check(.backend)
            #endif
            #if os(iOS)
            let settingsLinksBeforeFetch = NotificationSettingsPushQueue.finishedLinks
            #endif
            let pass = try await read(for: signIn)
            var changed = pass.reset.apply
            for reconciler in Self.reconcilers {
                changed = reconciler.init(app: app).reconcile(pass) || changed
            }
            SyncProgress.recordFullSync(coursesReset: pass.reset.remember, taken: pass.taken, for: signIn)
            if app.localEdits.overrideEditGeneration == pass.editGenerationAtFetch,
               let revision = pass.json["current_revision"] as? Int {
                app.feed.lastKnownRevision = revision
            }
            app.firstPullGate.notePull(signIn)
            ServerStatusTracker.shared.noteSyncResult(true)
            app.conflicts.retryOwedConflictCheck()
            #if os(iOS)
            app.notificationSettings.reconcile(
                snapshot: NotificationSettingsReconcile.documentSource(fromSnapshot: pass.json),
                linksBeforeSnapshot: settingsLinksBeforeFetch
            )
            #endif
            return .synced
        } catch is FullSyncAbandoned {
            return .skipped
        } catch {
            guard !Self.isCancellation(error), mayWrite(for: signIn) else { return .skipped }
            ServerStatusTracker.shared.noteSyncResult(false)
            AppLogger.sync.error("syncOverrides failed: \(error, privacy: .private)")
            return .failed
        }
    }

    private func read(for signIn: SignIn) async throws -> FullSyncPass {
        let coordinator = app.cloudSyncCoordinator
        let preFetchQueued = await coordinator.pendingAssignmentOverrideIds()
            .union(coordinator.pendingCourseIgnoreKeys()).union(app.localEdits.marksAndIgnoresEnqueuing)
        let preFetchCourseOverrides = await coordinator.pendingCourseOverrides()
        let editGenerationAtFetch = app.localEdits.overrideEditGeneration
        let fetchedAt = Date()
        let (json, fetchedDeletes) = try await coordinator.courseDeletes(around: {
            try await app.pushCoordinator.fetchFullSync(for: signIn)
        })
        try requireMayWrite(for: signIn)
        let marks = ServerMarks(json)
        let courseOverrides = json["course_overrides"] as? [[String: Any]] ?? []
        let serverIgnoredCourses = CourseIgnoresReconciler.serverIgnoredCourses(courseOverrides, syncsCourses: Defaults[.syncCourses])

        let assignments = AssignmentStore.shared
        let localArchived = assignments.loadArchivedAssignmentIds()
        let localCompleted = assignments.loadLocallyCompletedAssignmentIds()
        let syncsMarks = Defaults[.syncAssignments]
        let isMigrating = syncsMarks && sendLocalMarksIfFirstSync(
            server: marks, serverIgnoredCourses: serverIgnoredCourses,
            localArchived: localArchived, localCompleted: localCompleted, for: signIn
        )
        if syncsMarks { SyncProgress.noteMarksSynced(for: signIn) }

        let inFlight = await coordinator.pendingAssignmentOverrideIds().union(coordinator.pendingCourseIgnoreKeys())
        try requireMayWrite(for: signIn)
        let before = SyncPolicy.current
        let takesCourses = before.switchedOn.contains(.courses) && !before.pendingChecks.contains(.courses)
        let reset = CourseReset.decide(
            server: Self.backendDate(json["courses_reset_at"]), lastSeen: Defaults[.lastSeenCoursesResetAt],
            takesCourses: takesCourses
        )
        let settled = try await Self.settleCourseEditsThenReadPolicy(
            fetchedDeletes, takingCourses: takesCourses,
            settle: { try await self.settleQueuedCourseEdits(deleting: $0, reset: reset, for: signIn) },
            adds: { await coordinator.courseAddKeys(unlandedAt: fetchedAt) },
            mayWrite: { mayWrite(for: signIn) }, policy: { SyncPolicy.current }
        )
        let policy = settled.policy

        let marksLeftFor = SyncPolicy.reasonToLeaveMarks(
            syncsMarks: syncsMarks && Defaults[.syncAssignments],
            conflictCheckPending: policy.pendingChecks.contains(.assignments),
            uploadedLocalMarks: isMigrating,
            editedDuringFetch: app.localEdits.overrideEditGeneration != editGenerationAtFetch
        )
        return FullSyncPass(
            json: json, signIn: signIn, fetchedAt: fetchedAt, policy: policy, marks: marks,
            courseOverrides: courseOverrides, serverIgnoredCourses: serverIgnoredCourses,
            localArchived: localArchived, localCompleted: localCompleted,
            queuedMarkAndIgnoreKeys: preFetchQueued.union(app.localEdits.marksAndIgnoresEnqueuing).union(inFlight),
            courseDeletes: settled.deletes, courseAdds: settled.adds,
            heldCourseOverrides: coordinator.courseOverridesToHold(since: preFetchCourseOverrides),
            marksLeftFor: marksLeftFor, taken: policy.categoriesTaken(marksLeftFor: marksLeftFor),
            reset: reset, editGenerationAtFetch: editGenerationAtFetch
        )
    }

    private func sendLocalMarksIfFirstSync(
        server marks: ServerMarks, serverIgnoredCourses: [CourseIgnoresReconciler.ServerIgnoredCourse]?,
        localArchived: Set<String>, localCompleted: Set<String>, for signIn: SignIn
    ) -> Bool {
        let localIgnoredCourses = AssignmentStore.shared.loadIgnoredAssignmentCourses()
        guard Self.uploadsLocalMarksAsFirstSync(
            syncedBefore: Defaults[.assignmentMarksSyncedOnce],
            serverHasMarks: !marks.archived.isEmpty || !marks.completed.isEmpty
                || serverIgnoredCourses?.isEmpty == false,
            localHasMarks: !localArchived.isEmpty || !localCompleted.isEmpty || !localIgnoredCourses.isEmpty
        ) else { return false }
        for id in localArchived { app.edits.syncAssignmentOverride(moodleId: id, status: "archived", for: signIn) }
        for id in localCompleted {
            app.edits.syncAssignmentOverride(moodleId: id, status: "locally_completed", for: signIn)
        }
        app.edits.syncCourseIgnores(localIgnoredCourses, for: signIn)
        return true
    }

    struct SettledCourseEdits {
        let deletes: Set<String>
        let adds: Set<String>
        let policy: SyncPolicy
    }

    static func settleCourseEditsThenReadPolicy(
        _ deletes: Set<String>, takingCourses: Bool,
        settle: (Set<String>) async throws -> Set<String>, adds: () async -> Set<String>,
        mayWrite: () -> Bool, policy: () -> SyncPolicy
    ) async throws -> SettledCourseEdits {
        let deletes = takingCourses ? try await settle(deletes) : deletes
        let adds = await adds()
        guard mayWrite() else { throw FullSyncAbandoned() }
        return SettledCourseEdits(deletes: deletes, adds: adds, policy: policy())
    }
}

nonisolated struct FullSyncAbandoned: Error {}

nonisolated struct ServerMarks: Sendable {
    let archived: Set<String>
    let completed: Set<String>

    init(archived: Set<String>, completed: Set<String>) {
        self.archived = archived
        self.completed = completed
    }

    init(_ json: [String: Any]) {
        var archived = Set<String>()
        var completed = Set<String>()
        let assignments = json["assignments"] as? [[String: Any]]
        for row in json["assignment_overrides"] as? [[String: Any]] ?? [] {
            guard let status = row["local_status"] as? String else { continue }
            let moodleId: String?
            if let id = row["moodle_assignment_id"] as? Int {
                moodleId = String(id)
            } else if let assignPk = row["user_assignment_id"] as? Int, let assignments {
                moodleId = assignments.first(where: { ($0["id"] as? Int) == assignPk })
                    .flatMap { $0["moodle_assignment_id"] as? Int }.map(String.init)
            } else {
                moodleId = nil
            }
            guard let moodleId else { continue }
            switch status {
            case "archived", "ignored": archived.insert(moodleId)
            case "locally_completed": completed.insert(moodleId)
            default: break
            }
        }
        self.archived = archived
        self.completed = completed
    }
}

struct FullSyncPass {
    let json: [String: Any]
    let signIn: SignIn
    let fetchedAt: Date
    let policy: SyncPolicy
    let marks: ServerMarks
    let courseOverrides: [[String: Any]]
    let serverIgnoredCourses: [CourseIgnoresReconciler.ServerIgnoredCourse]?
    let localArchived: Set<String>
    let localCompleted: Set<String>
    let queuedMarkAndIgnoreKeys: Set<String>
    let courseDeletes: Set<String>
    let courseAdds: Set<String>
    let heldCourseOverrides: (colors: Set<String>, names: Set<String>)
    let marksLeftFor: SyncPolicy.MarksLeftReason?
    let taken: Set<SyncCategory>
    let reset: (apply: Bool, remember: Date)
    let editGenerationAtFetch: Int

    var coursesArray: [[String: Any]] { json["courses"] as? [[String: Any]] ?? [] }
}

@MainActor
protocol CategoryReconciler {
    init(app: AppEnvironment)
    func reconcile(_ pass: FullSyncPass) -> Bool
}
