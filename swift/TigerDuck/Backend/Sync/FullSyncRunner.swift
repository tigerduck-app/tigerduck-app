import Defaults
import Foundation
import os
#if canImport(UIKit)
import UIKit
#endif

/// Reads `GET /sync/full` and hands the snapshot to one `CategoryReconciler` per category, in a
/// fixed order: marks, course ignores, colours and names, holidays, the roster; then it stores
/// the reset stamp and the revision.
@MainActor
final class FullSyncRunner {
    let gate = FullSyncGate()
    private unowned let app: AppState

    init(app: AppState) {
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
        // server's view over them. Revision polling syncs at the next return to the app.
        guard UIApplication.shared.isProtectedDataAvailable else { return .skipped }
        #endif
        if gate.isRunning {
            AppLogger.sync.info("[syncOverrides] already in flight, follow-up: \(followUpIfBusy, privacy: .public)")
        }
        return await gate.run(followUp: followUpIfBusy, mayFollow: { Defaults[.cloudSyncEnabled] }) {
            await self.run()
        }
    }

    private func run() async -> FullSyncOutcome {
        let ticket = app.authService.session.ticket
        await app.authService.ensureBackendSignedIn()
        guard await app.authTokenManager.isLoggedIn, app.fullSyncMayWrite(since: ticket) else { return .skipped }
        await app.retryUnsentEdits()
        do {
            #if DEBUG
            try await ServerFailureSimulator.shared.check(.backend)
            #endif
            #if os(iOS)
            let settingsLinksBeforeFetch = NotificationSettingsPushQueue.finishedLinks
            #endif
            guard let pass = try await read(ticket: ticket) else { return .skipped }
            var changed = pass.reset.apply
            for reconciler in Self.reconcilers {
                changed = reconciler.init(app: app).reconcile(pass) || changed
            }
            AppState.recordFullSync(coursesReset: pass.reset.remember, taken: pass.taken)
            if app.overrideEditGeneration == pass.editGenerationAtFetch,
               let revision = pass.json["current_revision"] as? Int {
                app._lastKnownRevision = revision
            }
            app.syncTarget.notePull(ticket)
            ServerStatusTracker.shared.noteSyncResult(true)
            app.recordSyncSource(.backend)
            app.retryOwedConflictCheck()
            #if os(iOS)
            app.reconcileNotificationSettings(
                snapshot: NotificationSettingsSync.documentSource(fromSnapshot: pass.json),
                linksBeforeSnapshot: settingsLinksBeforeFetch
            )
            #endif
            return .synced
        } catch {
            guard !AppState.isCancellation(error), app.fullSyncMayWrite(since: ticket) else { return .skipped }
            ServerStatusTracker.shared.noteSyncResult(false)
            app.recordSyncSource(.local)
            AppLogger.sync.error("syncOverrides failed: \(error, privacy: .private)")
            return .failed
        }
    }

    /// Reads the snapshot with what this device has queued around it, settles the queued course
    /// edits a reset overtook and sends the local marks of a first sync; nil when a sign-out or a
    /// switch turned off came in between.
    private func read(ticket: AccountSession.Ticket) async throws -> FullSyncPass? {
        let coordinator = app.cloudSyncCoordinator
        let preFetchProtected = await coordinator.pendingAssignmentOverrideIds()
            .union(coordinator.pendingCourseIgnoreKeys()).union(app.pendingOverrides)
        let preFetchCourseOverrides = await coordinator.pendingCourseOverrides()
        let editGenerationAtFetch = app.overrideEditGeneration
        let fetchedAt = Date()
        let (json, fetchedDeletes) = try await coordinator.courseDeletes(around: {
            try await app.pushCoordinator.fetchFullSync()
        })
        guard app.fullSyncMayWrite(since: ticket) else { return nil }
        let marks = ServerMarks(json)
        let courseOverrides = json["course_overrides"] as? [[String: Any]] ?? []
        let serverIgnoredCourses = AppState.serverIgnoredCourses(courseOverrides, syncsCourses: Defaults[.syncCourses])

        let assignments = AssignmentStore.shared
        let localArchived = assignments.loadArchivedAssignmentIds()
        let localCompleted = assignments.loadLocallyCompletedAssignmentIds()
        let localIgnoredCourses = assignments.loadIgnoredAssignmentCourses()
        let syncsMarks = Defaults[.syncAssignments]
        let isMigrating = syncsMarks && AppState.uploadsLocalMarksAsFirstSync(
            syncedBefore: Defaults[.assignmentMarksSyncedOnce],
            serverHasMarks: !marks.archived.isEmpty || !marks.completed.isEmpty
                || serverIgnoredCourses?.isEmpty == false,
            localHasMarks: !localArchived.isEmpty || !localCompleted.isEmpty || !localIgnoredCourses.isEmpty
        )
        if isMigrating {
            for id in localArchived { app.syncAssignmentOverride(moodleId: id, status: "archived") }
            for id in localCompleted { app.syncAssignmentOverride(moodleId: id, status: "locally_completed") }
            app.syncCourseIgnores(localIgnoredCourses)
        }
        if syncsMarks { Defaults[.assignmentMarksSyncedOnce] = true }

        let inFlight = await coordinator.pendingAssignmentOverrideIds().union(coordinator.pendingCourseIgnoreKeys())
        guard app.fullSyncMayWrite(since: ticket) else { return nil }
        let before = SyncPolicy.current
        let takesCourses = before.switchedOn.contains("courses") && !before.pendingChecks.contains("courses")
        let reset = AppState.coursesReset(
            server: AppState.backendDate(json["courses_reset_at"]), lastSeen: Defaults[.lastSeenCoursesResetAt],
            takesCourses: takesCourses
        )
        guard let settled = await Self.settle(
            fetchedDeletes, takingCourses: takesCourses,
            settle: { await app.settleQueuedCourseEdits(deleting: $0, reset: reset, ticket: ticket) },
            adds: { await coordinator.courseAddKeys(unlandedAt: fetchedAt) },
            mayWrite: { app.fullSyncMayWrite(since: ticket) }, policy: { SyncPolicy.current }
        ) else { return nil }
        let policy = settled.policy

        let marksLeftFor = SyncPolicy.reasonToLeaveMarks(
            syncsMarks: syncsMarks && Defaults[.syncAssignments],
            conflictCheckPending: policy.pendingChecks.contains("assignments"),
            uploadedLocalMarks: isMigrating,
            editedDuringFetch: app.overrideEditGeneration != editGenerationAtFetch
        )
        return FullSyncPass(
            json: json, ticket: ticket, fetchedAt: fetchedAt, policy: policy, marks: marks,
            courseOverrides: courseOverrides, serverIgnoredCourses: serverIgnoredCourses,
            localArchived: localArchived, localCompleted: localCompleted,
            protected: preFetchProtected.union(app.pendingOverrides).union(inFlight),
            courseDeletes: settled.deletes, courseAdds: settled.adds,
            heldCourseOverrides: coordinator.courseOverridesToHold(since: preFetchCourseOverrides),
            marksLeftFor: marksLeftFor, taken: policy.categoriesTaken(marksLeftFor: marksLeftFor),
            reset: reset, editGenerationAtFetch: editGenerationAtFetch
        )
    }

    /// Settles the queued course edits and reads the adds still on their way, then the policy, so
    /// a switch turned off or a conflict check begun during those awaits holds for this pass. Nil
    /// when the pass may no longer write.
    static func settle(
        _ deletes: Set<String>, takingCourses: Bool,
        settle: (Set<String>) async -> Set<String>?, adds: () async -> Set<String>,
        mayWrite: () -> Bool, policy: () -> SyncPolicy
    ) async -> (deletes: Set<String>, adds: Set<String>, policy: SyncPolicy)? {
        var deletes = deletes
        if takingCourses {
            guard let settled = await settle(deletes) else { return nil }
            deletes = settled
        }
        let adds = await adds()
        guard mayWrite() else { return nil }
        return (deletes, adds, policy())
    }
}

/// The assignment marks a snapshot holds, by Moodle assignment id.
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

/// One full sync's snapshot, with what this device held queued around reading it.
struct FullSyncPass {
    let json: [String: Any]
    let ticket: AccountSession.Ticket
    let fetchedAt: Date
    let policy: SyncPolicy
    let marks: ServerMarks
    let courseOverrides: [[String: Any]]
    let serverIgnoredCourses: [AppState.ServerIgnoredCourse]?
    let localArchived: Set<String>
    let localCompleted: Set<String>
    /// Marks and course ignores queued or in flight here, which the snapshot does not hold yet.
    let protected: Set<String>
    let courseDeletes: Set<String>
    let courseAdds: Set<String>
    let heldCourseOverrides: (colors: Set<String>, names: Set<String>)
    let marksLeftFor: SyncPolicy.MarksLeftReason?
    let taken: Set<String>
    let reset: (apply: Bool, remember: Date)
    let editGenerationAtFetch: Int

    var coursesArray: [[String: Any]] { json["courses"] as? [[String: Any]] ?? [] }
}

/// Applies one category of a full sync's snapshot; true when it changed what this device holds.
@MainActor
protocol CategoryReconciler {
    static var category: String { get }
    init(app: AppState)
    func reconcile(_ pass: FullSyncPass) -> Bool
}
