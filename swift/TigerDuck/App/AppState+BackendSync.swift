// Sync of the user's own marks with the TigerDuck backend: done/ignored, course colour and name
// overrides, manual courses. The assignment list itself always comes from Moodle directly.
// Pull is `syncOverridesFromBackend`; push is the `sync*Override`, `upload*`, `delete*` family.

import SwiftUI
import SwiftData
import Defaults
import os

extension AppState {

    /// Fetch override state (done/ignored) from the backend and apply it
    /// locally. The assignment LIST comes from Moodle-direct (proven
    /// semester filtering); this only syncs the user's swipe marks.
    ///
    /// One runs at a time. `followUpIfBusy` is for a sync trigger push: one that arrives during
    /// a pull waits for one more, since that pull may predate the change it announces, and gets
    /// that one's outcome.
    @discardableResult
    func syncOverridesFromBackend(followUpIfBusy: Bool = false) async -> FullSyncOutcome {
        guard Defaults[.cloudSyncEnabled] else { return .skipped }
        #if os(iOS)
        // A sync trigger can launch the app behind the lock screen, where the local marks,
        // courses and colours cannot be opened and read as empty, and a sync would write the
        // server's view over them. Revision polling syncs at the next return to the app.
        guard UIApplication.shared.isProtectedDataAvailable else { return .skipped }
        #endif
        if fullSyncGate.isRunning {
            AppLogger.sync.info("[syncOverrides] already in flight, follow-up: \(followUpIfBusy, privacy: .public)")
        }
        return await fullSyncGate.run(followUp: followUpIfBusy, mayFollow: { Defaults[.cloudSyncEnabled] }) {
            await runFullSync(retried: false)
        }
    }

    private func runFullSync(retried: Bool) async -> FullSyncOutcome {
        // Sign-out clears what this writes but cancels only `syncTask`, which a poll, a push or a
        // pull does not run in. So no write below follows an await without this check.
        let generation = authService.loginGeneration
        await authService.ensureBackendSignedIn()
        guard await authTokenManager.isLoggedIn, fullSyncMayWrite(since: generation) else { return .skipped }
        await retryUnsentEdits()
        do {
            #if DEBUG
            try await ServerFailureSimulator.shared.check(.backend)
            #endif
            // Sample the pending set on both sides of the fetch: an edit whose
            // PATCH fully lands while the fetch is in flight leaves both the
            // marker set and the outbox before the (stale) payload arrives.
            let preFetchInFlight = await cloudSyncCoordinator.pendingAssignmentOverrideIds()
                .union(cloudSyncCoordinator.pendingCourseIgnoreKeys())
            let preFetchProtected = preFetchInFlight.union(pendingOverrides)
            let preFetchCourseOverrides = await cloudSyncCoordinator.pendingCourseOverrides()
            let editGenerationAtFetch = overrideEditGeneration
            let fetchedAt = Date()
            #if os(iOS)
            let settingsLinksBeforeFetch = NotificationSettingsPushQueue.finishedLinks
            #endif
            let (json, courseDeletes) = try await cloudSyncCoordinator.courseDeletes(around: {
                try await pushCoordinator.fetchFullSync()
            })
            guard fullSyncMayWrite(since: generation) else { return .skipped }
            // Whether this sync changed anything on the device. Only then does it post
            // `dataDidUpdate`, which reloads every page, the widgets, the Watch and the schedule.
            var changed = false
            let overridesArray = json["assignment_overrides"] as? [[String: Any]] ?? []

            var serverArchivedIds = Set<String>()
            var serverCompletedIds = Set<String>()
            for o in overridesArray {
                guard let status = o["local_status"] as? String else { continue }
                let moodleId: String?
                if let mid = o["moodle_assignment_id"] as? Int {
                    moodleId = String(mid)
                } else if let assignPk = o["user_assignment_id"] as? Int,
                          let assignments = json["assignments"] as? [[String: Any]] {
                    moodleId = assignments.first(where: { ($0["id"] as? Int) == assignPk })
                        .flatMap { $0["moodle_assignment_id"] as? Int }.map(String.init)
                } else {
                    moodleId = nil
                }
                guard let moodleId else { continue }
                switch status {
                case "archived", "ignored": serverArchivedIds.insert(moodleId)
                case "locally_completed": serverCompletedIds.insert(moodleId)
                default: break
                }
            }

            let coursesArray = json["courses"] as? [[String: Any]] ?? []
            let courseOverrides = json["course_overrides"] as? [[String: Any]] ?? []
            let serverIgnoredCourses = Self.serverIgnoredCourses(courseOverrides, syncsCourses: Defaults[.syncCourses])

            // First-time migration: upload local overrides when the server has none. This skips
            // only conflict detection; course overrides, hard-delete detection and `dataDidUpdate`
            // still run, to pick up colour and name changes and cross-device deletions.
            let localArchivedIds = DataCache.shared.loadArchivedAssignmentIds()
            let localCompletedIds = DataCache.shared.loadLocallyCompletedAssignmentIds()
            let localIgnoredCourses = DataCache.shared.loadIgnoredAssignmentCourses()
            let syncsMarks = Defaults[.syncAssignments]
            let isMigrating = syncsMarks && Self.uploadsLocalMarksAsFirstSync(
                syncedBefore: Defaults[.assignmentMarksSyncedOnce],
                serverHasMarks: !serverArchivedIds.isEmpty || !serverCompletedIds.isEmpty
                    || serverIgnoredCourses?.isEmpty == false,
                localHasMarks: !localArchivedIds.isEmpty || !localCompletedIds.isEmpty || !localIgnoredCourses.isEmpty
            )
            if isMigrating {
                for id in localArchivedIds { syncAssignmentOverride(moodleId: id, status: "archived") }
                for id in localCompletedIds { syncAssignmentOverride(moodleId: id, status: "locally_completed") }
                syncCourseIgnores(localIgnoredCourses)
            }
            if syncsMarks { Defaults[.assignmentMarksSyncedOnce] = true }

            // Ops still queued in the outbox are local edits in flight to the
            // server — differences against the (possibly stale) pull payload
            // are not cross-device conflicts.
            let inFlightOverrides = await cloudSyncCoordinator.pendingAssignmentOverrideIds()
                .union(cloudSyncCoordinator.pendingCourseIgnoreKeys())
            // A colour or name edit both queued and sent while the fetch is out is in neither sample.
            let queuedCourseOverrides = await cloudSyncCoordinator.pendingCourseOverrides()
            guard fullSyncMayWrite(since: generation) else { return .skipped }
            let protectedOverrides = preFetchProtected
                .union(pendingOverrides)
                .union(inFlightOverrides)

            let pendingConflicts = Defaults[.pendingConflictCategories]
            let marksLeftFor = Self.reasonToLeaveMarks(
                // Again after the await: the switch may have gone off while it waited.
                syncsMarks: syncsMarks && Defaults[.syncAssignments],
                conflictCheckPending: pendingConflicts.contains("assignments"),
                uploadedLocalMarks: isMigrating,
                editedDuringFetch: overrideEditGeneration != editGenerationAtFetch
            )
            // Read once, for the steps below and for what this sync records as synced.
            let taken = Self.categoriesTaken(
                switchedOn: Self.switchedOnCategories(), pendingChecks: pendingConflicts, marksLeftFor: marksLeftFor
            )
            if let reason = marksLeftFor {
                AppLogger.sync.info("[syncOverrides] skipping assignment overrides — \(reason.rawValue, privacy: .public)")
            } else {
                var conflicts: [(id: String, kind: String, label: String, local: String, server: String)] = []
                let allIds = serverArchivedIds.union(serverCompletedIds).union(localArchivedIds).union(localCompletedIds)
                let assignmentCache = DataCache.shared.loadAssignments()
                let assignmentsByMoodleId = Dictionary(assignmentCache.map { ($0.assignmentId, $0) }, uniquingKeysWith: { first, _ in first })
                for id in allIds where !protectedOverrides.contains(id) {
                    let serverStatus: String
                    if serverArchivedIds.contains(id) { serverStatus = "ignored" }
                    else if serverCompletedIds.contains(id) { serverStatus = "locally_completed" }
                    else { serverStatus = "none" }
                    let localStatus: String
                    if localArchivedIds.contains(id) { localStatus = "ignored" }
                    else if localCompletedIds.contains(id) { localStatus = "locally_completed" }
                    else { localStatus = "none" }
                    if serverStatus != localStatus && localStatus != "none" && serverStatus != "none" {
                        let title = assignmentsByMoodleId[id]?.displayTitle ?? "ID \(id)"
                        conflicts.append((id: id, kind: String(localized: "live_activity_status_assignment_short"), label: title, local: localStatus, server: serverStatus))
                    }
                }

                // Always apply non-conflicting items
                let conflictIds = Set(conflicts.map(\.id))
                let currentArchived = DataCache.shared.loadArchivedAssignmentIds()
                let currentCompleted = DataCache.shared.loadLocallyCompletedAssignmentIds()
                var safeArchived = Self.mergedMarks(
                    server: serverArchivedIds.subtracting(conflictIds),
                    local: currentArchived,
                    protected: protectedOverrides
                )
                var safeCompleted = Self.mergedMarks(
                    server: serverCompletedIds.subtracting(conflictIds),
                    local: currentCompleted,
                    protected: protectedOverrides
                )
                // Preserve local state for conflicting items until user resolves
                for c in conflicts {
                    switch c.local {
                    case "ignored", "archived": safeArchived.insert(c.id)
                    case "locally_completed": safeCompleted.insert(c.id)
                    default: break
                    }
                }
                if safeArchived != currentArchived {
                    DataCache.shared.replaceArchivedAssignmentIds(safeArchived)
                    changed = true
                }
                if safeCompleted != currentCompleted {
                    DataCache.shared.replaceLocallyCompletedAssignmentIds(safeCompleted)
                    changed = true
                }

                AppLogger.sync.info("applied: \(safeArchived.count, privacy: .public) archived, \(safeCompleted.count, privacy: .public) completed, \(conflicts.count, privacy: .public) conflicts pending")

                if !conflicts.isEmpty {
                    syncConflicts = conflicts.map { SyncConflictItem(id: $0.id, kind: $0.kind, label: $0.label, localStatus: $0.local, serverStatus: $0.server) }
                    pendingSyncServerArchived = serverArchivedIds
                    pendingSyncServerCompleted = serverCompletedIds
                }

                // Read again: the switch may have gone off while the outbox was read.
                if let serverIgnoredCourses, Defaults[.syncCourses] {
                    changed = applyIgnoredCourses(
                        serverIgnoredCourses, decided: Self.serverDecidedCourses(courseOverrides),
                        coursesArray: coursesArray, protected: protectedOverrides, deleting: courseDeletes,
                        fetchedAt: fetchedAt
                    ) || changed
                }
            }

            let takesColors = taken.contains("course_colors")
            let takesNames = taken.contains("course_names")
            if !takesColors && !takesNames {
                AppLogger.sync.info("[syncOverrides] skipping course overrides — switched off or conflict check pending")
            } else if !courseOverrides.isEmpty {
                changed = applyCourseOverrides(
                    courseOverrides, coursesArray: coursesArray, colors: takesColors, names: takesNames,
                    holdingColors: preFetchCourseOverrides.colors.union(queuedCourseOverrides.colors),
                    holdingNames: preFetchCourseOverrides.names.union(queuedCourseOverrides.names)
                ) || changed
            }

            // Holiday exceptions are a notification setting, not course or assignment data,
            // so no per-category sync toggle gates them. An absent key means an older backend
            // that does not send the section; the local set stands.
            if let holidayRows = json["holiday_overrides"] as? [[String: Any]] {
                // `notify: false` rows exist server-side so a device can tell
                // "turned it off" from "never set it"; only the true ones
                // belong in the opted-in set.
                let optedIn = Set(
                    holidayRows.compactMap { row -> Int? in
                        guard row["notify"] as? Bool == true else { return nil }
                        return row["holiday_id"] as? Int
                    }
                )
                changed = AcademicCalendarStore.shared.applySyncedOverrides(optedIn, fetchedAt: fetchedAt) || changed
            }

            // Conflict resolution: detect reset + process tombstones
            let coursesResetAt = Self.backendDate(json["courses_reset_at"])
            let tombstoneArray = json["course_tombstones"] as? [[String: Any]] ?? []
            let lastSeenReset = Defaults[.lastSeenCoursesResetAt]
            let reset = Self.coursesReset(
                server: coursesResetAt, lastSeen: lastSeenReset, takesCourses: taken.contains("courses")
            )

            if reset.apply {
                DataCache.shared.saveUserAddedCourses([])
                DataCache.shared.saveDeletedCourseNos([])
                changed = true
                AppLogger.sync.info("[sync] courses reset detected (reset=\(String(describing: coursesResetAt), privacy: .public) > lastSeen=\(String(describing: lastSeenReset), privacy: .public)), wiped local state")
            }
            Self.recordFullSync(coursesReset: reset.remember, taken: taken)

            if taken.contains("courses") {
                changed = reconcileCourses(
                    serverRows: coursesArray, tombstones: tombstoneArray, deleting: courseDeletes, fetchedAt: fetchedAt
                ) || changed
            } else if pendingConflicts.contains("courses") {
                AppLogger.sync.info("[syncOverrides] skipping course sync — conflict check pending")
            }

            // Advance the revision watermark so the poller does not re-trigger after a full
            // sync. If an edit raced the fetch and the reconcile was skipped, leave it stale
            // so the next poll re-pulls: the edit's PATCH may fail and never bump the revision.
            if overrideEditGeneration == editGenerationAtFetch,
               let rev = json["current_revision"] as? Int {
                _lastKnownRevision = rev
            }

            if changed {
                NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
            }
            ServerStatusTracker.shared.noteSyncResult(true)
            recordSyncSource(.backend)
            retryOwedConflictCheck()
            #if os(iOS)
            // The fetch landed, so there is a network and a session: settle the notification
            // settings document too, so changes from other devices show up. This runs after the
            // retry queued at the top, and the routine never reads over an edit waiting to go up.
            reconcileNotificationSettings(
                snapshot: NotificationSettingsSync.documentSource(fromSnapshot: json),
                linksBeforeSnapshot: settingsLinksBeforeFetch
            )
            #endif
            return .synced
        } catch {
            guard !Self.isCancellation(error), fullSyncMayWrite(since: generation) else { return .skipped }
            ServerStatusTracker.shared.noteSyncResult(false)
            recordSyncSource(.local)
            var outcome = FullSyncOutcome.failed
            if case PushAPIError.httpStatus(401, _) = error, !retried {
                let reloginOk = await attemptBackendRelogin()
                if reloginOk {
                    AppLogger.sync.info("auto-relogin succeeded, retrying sync")
                    try? await Task.sleep(for: .milliseconds(500))
                    guard fullSyncMayWrite(since: generation) else { return .skipped }
                    outcome = await runFullSync(retried: true)
                }
            }
            AppLogger.sync.error("syncOverrides failed: \(error, privacy: .private)")
            return outcome
        }
    }

    /// Whether a full sync's error is its own cancellation, as at the time limit of a sync trigger
    /// push, which says nothing about the server. `URLSession` throws `URLError.cancelled` for it.
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// Re-sends the edits whose upload never landed. Every full sync starts with this, and so does
    /// a poll the change feed settles without one: both mean a network and a session.
    func retryUnsentEdits() async {
        // Not awaited: this is a repair, not a precondition. Its pending
        // marker makes `applySyncedOverrides` sit out this cycle rather than
        // race it, and the next sync applies the settled state.
        retryUnacknowledgedHolidayOverrides()
        #if os(iOS)
        // Same repair for a reminder or Live Activity preference whose settings document
        // write never landed (dropped debounce, expired session, offline, 5xx). A no-op
        // unless something is outstanding.
        retryUnacknowledgedNotificationSettings()
        #endif
        await cloudSyncCoordinator.requeueParkedMarks()
    }

    /// Why a pull leaves the server's marks unapplied, or nil to apply them. With the Assignments
    /// switch off, marks stay on this device. Marks just uploaded have nothing to reconcile until
    /// the server echoes them, and a payload fetched before a local edit predates it: the next
    /// pull, which the edit's revision bump starts, compares the settled state.
    nonisolated static func reasonToLeaveMarks(
        syncsMarks: Bool,
        conflictCheckPending: Bool,
        uploadedLocalMarks: Bool,
        editedDuringFetch: Bool
    ) -> MarksLeftReason? {
        if !syncsMarks { return .switchedOff }
        if conflictCheckPending { return .conflictCheckPending }
        if uploadedLocalMarks { return .uploadedLocalMarks }
        if editedDuringFetch { return .editedDuringFetch }
        return nil
    }

    nonisolated enum MarksLeftReason: String, Sendable {
        case switchedOff = "Assignments sync is off"
        case conflictCheckPending = "conflict check pending"
        case uploadedLocalMarks = "local marks just uploaded"
        case editedDuringFetch = "local edit during fetch"
    }

    /// The categories a full sync takes the server's data of, which it applies and records as
    /// synced: those switched on, less the ones it leaves alone. A pending re-enable check holds
    /// back its category, and one on colours or names holds back both, which one step applies.
    /// Marks left unapplied count only when the sync uploaded this device's to a server with none.
    nonisolated static func categoriesTaken(
        switchedOn: Set<String>,
        pendingChecks: Set<String>,
        marksLeftFor reason: MarksLeftReason?
    ) -> Set<String> {
        let holdsCourseOverrides = pendingChecks.contains("course_colors") || pendingChecks.contains("course_names")
        return switchedOn.filter { category in
            switch category {
            case "assignments": reason == nil || reason == .uploadedLocalMarks
            case "course_colors", "course_names": !holdsCourseOverrides
            default: !pendingChecks.contains(category)
            }
        }
    }

    /// Whether a pull uploads this device's marks instead of applying the server's. Only the
    /// account's first sync on this device does: later, a server with no marks means they were
    /// cleared on another device, and a stale copy here would bring them back.
    nonisolated static func uploadsLocalMarksAsFirstSync(
        syncedBefore: Bool,
        serverHasMarks: Bool,
        localHasMarks: Bool
    ) -> Bool {
        !syncedBefore && !serverHasMarks && localHasMarks
    }

    /// One status's marks after a pull: the server's, except for marks with an edit not on the
    /// server yet (`protected`), which keep the local status whether it sets or clears the mark.
    nonisolated static func mergedMarks(
        server: Set<String>,
        local: Set<String>,
        protected: Set<String>
    ) -> Set<String> {
        server.subtracting(protected).union(local.intersection(protected))
    }

    /// The assignments whose mark Keep Local clears on the server: marked there, not on this device.
    nonisolated static func assignmentMarksToClear(server: Set<String>, local: Set<String>) -> Set<String> {
        server.subtracting(local)
    }

    /// A course the server ignores every assignment of, from the snapshot's `course_overrides`.
    nonisolated struct ServerIgnoredCourse: Equatable {
        let semester: String
        let courseNo: String
        /// The id a PATCH names the course by, the row's `moodle_id`.
        let moodleId: String?
        let moodleCourseId: Int?

        var key: String { CourseTombstone.key(semester: semester, courseNo: courseNo) }
    }

    /// The courses the server ignores every assignment of, or nil when there are none to take:
    /// from a backend without the setting, whose rows carry no `ignore_assignments`, and with the
    /// Courses sync switch off, which the setting follows with the Assignments switch.
    nonisolated static func serverIgnoredCourses(
        _ overrides: [[String: Any]],
        syncsCourses: Bool
    ) -> [ServerIgnoredCourse]? {
        guard syncsCourses, overrides.allSatisfy({ $0["ignore_assignments"] != nil }) else { return nil }
        return overrides.compactMap { row in
            guard row["ignore_assignments"] as? Bool == true,
                  let semester = row["semester"] as? String, !semester.isEmpty,
                  let courseNo = row["course_no"] as? String, !courseNo.isEmpty
            else { return nil }
            return ServerIgnoredCourse(
                semester: semester,
                courseNo: courseNo,
                moodleId: row["moodle_id"] as? String ?? (row["moodle_id"] as? Int).map(String.init),
                moodleCourseId: row["moodle_course_id"] as? Int
            )
        }
    }

    /// The courses ignored after a pull. A term the snapshot has courses in takes the server's,
    /// except a course whose setting has not reached the server (`protected`), which keeps this
    /// device's; a term it has no courses in is left as it is here.
    nonisolated static func mergedIgnoredCourses(
        server: Set<String>,
        local: Set<String>,
        protected: Set<String>,
        snapshotSemesters: Set<String>
    ) -> Set<String> {
        let isCovered = { (key: String) in
            CourseTombstone.parts(of: key).map { snapshotSemesters.contains($0.semester) } ?? false
        }
        return local.filter { !isCovered($0) }.union(mergedMarks(
            server: server.filter(isCovered),
            local: local.filter(isCovered),
            protected: protected
        ))
    }

    /// The courses Keep Local stops ignoring on the server: ignored there, not on this device.
    nonisolated static func courseIgnoresToClear(
        server: [ServerIgnoredCourse],
        local: Set<String>
    ) -> [ServerIgnoredCourse] {
        server.filter { !local.contains($0.key) }
    }

    /// Keys of the courses whose setting a device has sent, either way. A row the server made for
    /// a colour or a name holds none, and neither does a course row it dropped and got back.
    nonisolated static func serverDecidedCourses(_ overrides: [[String: Any]]) -> Set<String> {
        Set(overrides.compactMap { row in
            guard row["ignore_assignments"] as? Bool == true || row["ignore_assignments_updated_at"] is String,
                  let semester = row["semester"] as? String, !semester.isEmpty,
                  let courseNo = row["course_no"] as? String, !courseNo.isEmpty
            else { return nil }
            return CourseTombstone.key(semester: semester, courseNo: courseNo)
        })
    }

    /// The server row id of each course the snapshot's `courses` lists, by `CourseTombstone` key.
    nonisolated static func listedCourseRows(_ courses: [[String: Any]]) -> [String: Int] {
        var rows: [String: Int] = [:]
        for row in courses {
            guard let semester = row["semester"] as? String, !semester.isEmpty,
                  let courseNo = row["course_no"] as? String, !courseNo.isEmpty,
                  let id = row["id"] as? Int
            else { continue }
            rows[CourseTombstone.key(semester: semester, courseNo: courseNo)] = id
        }
        return rows
    }

    /// The listed courses some device deleted and added back since this device recorded `seen`
    /// (`courseRowIdsSeen`): each is a new server row while another row of its term kept its id.
    /// The delete took the course's setting, so a pull does not send this device's again. A term
    /// whose rows are all new was reset: by a device, by Keep Local, which resets each term it
    /// uploads and keeps this device's settings, or by the server dropping every course row while
    /// no device synced courses. A pull sends again what such a reset lost.
    nonisolated static func recreatedCourses(listed: [String: Int], seen: [String: Int]) -> Set<String> {
        let survivingTerms = Set(listed.compactMap { key, id in
            seen[key] == id ? CourseTombstone.parts(of: key)?.semester : nil
        })
        return Set(listed.compactMap { key, id in
            guard let old = seen[key], old != id,
                  let semester = CourseTombstone.parts(of: key)?.semester, survivingTerms.contains(semester)
            else { return nil }
            return key
        })
    }

    nonisolated static func listedCourses(_ courses: [[String: Any]]) -> Set<String> {
        Set(courses.compactMap { row in
            guard let semester = row["semester"] as? String, !semester.isEmpty,
                  let courseNo = row["course_no"] as? String, !courseNo.isEmpty
            else { return nil }
            return CourseTombstone.key(semester: semester, courseNo: courseNo)
        })
    }

    /// The keys among `keys` a pull leaves as they are here: those of a course deleted here whose
    /// DELETE may not have landed (`deleting`, as `unhideListedCourses` takes it), which the course
    /// reconcile keeps hidden as long, and every key of a term reset since the snapshot was fetched
    /// or resetting.
    nonisolated static func courseKeysPullLeaves(
        _ keys: Set<String>,
        deleting: Set<String>,
        resetSemesters: Set<String>
    ) -> Set<String> {
        keys.filter { key in
            guard let (semester, courseNo) = CourseTombstone.parts(of: key) else { return false }
            return CourseTombstone.isHidden(courseNo, semester: semester, in: deleting) || resetSemesters.contains(semester)
        }
    }

    /// The ignored courses after a pull, as `mergedIgnoredCourses` says, and the ones to send
    /// again (`resend`): ignored here and listed by the server with no device's setting, as when it
    /// dropped the settings with the course rows while no device synced courses. Those stay ignored.
    nonisolated static func ignoredCoursesAfterPull(
        server: Set<String>,
        decided: Set<String>,
        listed: Set<String>,
        local: Set<String>,
        protected: Set<String>,
        snapshotSemesters: Set<String>
    ) -> (ignored: Set<String>, resend: Set<String>) {
        let resend = local.intersection(listed).subtracting(decided).subtracting(protected)
        let ignored = mergedIgnoredCourses(
            server: server, local: local, protected: protected.union(resend), snapshotSemesters: snapshotSemesters
        )
        return (ignored, resend)
    }

    /// Whether the re-enabled Assignments switch's check finds the course settings differ, in the
    /// terms a pull would apply them to and as it would. A backend without the setting has none
    /// to compare.
    nonisolated static func ignoredCoursesDiffer(
        server: Set<String>?,
        decided: Set<String>,
        listed: Set<String>,
        local: Set<String>,
        snapshotSemesters: Set<String>
    ) -> Bool {
        guard let server else { return false }
        return ignoredCoursesAfterPull(
            server: server, decided: decided, listed: listed, local: local, protected: [],
            snapshotSemesters: snapshotSemesters
        ).ignored != local
    }

    /// The ignored courses whose numeric Moodle id the server lacks and this device knows. The
    /// server's reminder scan matches the assignments it fetches itself by that id.
    static func moodleCourseIdsToSend(
        _ server: [ServerIgnoredCourse],
        protected: Set<String>,
        lookup: (String) -> Int?
    ) -> [(course: ServerIgnoredCourse, moodleId: String, moodleCourseId: Int)] {
        server.compactMap { course in
            guard course.moodleCourseId == nil, !protected.contains(course.key),
                  let moodleId = course.moodleId, let moodleCourseId = lookup(moodleId)
            else { return nil }
            return (course, moodleId, moodleCourseId)
        }
    }

    /// Takes the server's ignored courses as `ignoredCoursesAfterPull` says, sends again the ones
    /// it lost, and sends the numeric Moodle ids it lacks. A course some device deleted and added
    /// back counts as decided (`recreatedCourses`). `deleting` holds the keys of the course deletes
    /// queued here. Returns whether the local set changed.
    private func applyIgnoredCourses(
        _ server: [ServerIgnoredCourse],
        decided: Set<String>,
        coursesArray: [[String: Any]],
        protected: Set<String>,
        deleting queuedDeletes: Set<String>,
        fetchedAt: Date
    ) -> Bool {
        let now = Date()
        let deleting = recentCourseDeletions.filter { now.timeIntervalSince($0.value) < Self.courseDeleteGraceInterval }
        let resetSemesters = resettingSemesters.union(
            DataCache.shared.loadSemesterResetAt().filter { $0.value > fetchedAt }.keys
        )
        let current = DataCache.shared.loadIgnoredAssignmentCourses()
        let listed = Self.listedCourses(coursesArray)
        let listedRows = Self.listedCourseRows(coursesArray)
        let recreated = Self.recreatedCourses(listed: listedRows, seen: Defaults[.courseRowIdsSeen])
        Defaults[.courseRowIdsSeen] = listedRows
        let protected = protected.union(Self.courseKeysPullLeaves(
            Set(server.map(\.key)).union(listed).union(current),
            deleting: Set(deleting.keys).union(queuedDeletes),
            resetSemesters: resetSemesters
        ))
        let missingIds = Self.moodleCourseIdsToSend(server, protected: protected) {
            DataCache.shared.lookupMoodleCourseId(idnumber: $0)
        }
        for (course, moodleId, moodleCourseId) in missingIds {
            Task { [weak self] in
                await self?.cloudSyncCoordinator.enqueueCourseIgnore(
                    semester: course.semester, courseNo: course.courseNo, moodleId: moodleId,
                    moodleCourseId: moodleCourseId, ignore: nil)
            }
        }
        if !missingIds.isEmpty { cloudSyncCoordinator.scheduleTick(after: 1) }

        let (merged, resend) = Self.ignoredCoursesAfterPull(
            server: Set(server.map(\.key)),
            decided: decided.union(recreated),
            listed: listed,
            local: current,
            protected: protected,
            snapshotSemesters: Set(coursesArray.compactMap { $0["semester"] as? String })
        )
        if !resend.isEmpty {
            AppLogger.sync.info("[syncOverrides] sending \(resend.count, privacy: .public) course settings the server lost again")
            syncCourseIgnores(resend)
        }
        guard merged != current else { return false }
        DataCache.shared.replaceIgnoredAssignmentCourses(merged)
        return true
    }

    /// A backend timestamp: Python `isoformat()`, which has microseconds unless they are zero.
    static func backendDate(_ value: Any?) -> Date? {
        guard let raw = value as? String else { return nil }
        return TigerDuckDateFormatters.withFractional.date(from: raw)
            ?? TigerDuckDateFormatters.withoutFractional.date(from: raw)
    }

    /// What a full sync does with the server's `courses_reset_at`: whether to apply it, dropping the
    /// hand-added and hidden courses, and what to keep for the next sync. Both times are the
    /// server's, so a device whose clock runs behind cannot take one reset for a new one on every
    /// sync. With nothing kept, this is the account's first sync here, which has nothing from before
    /// a reset to drop: it only keeps the reset, or `distantPast` when there is none yet, so that the
    /// first one counts as new. A sync that does not take courses (`takesCourses`), with the Courses
    /// switch off or a courses re-enable check pending, keeps them and the reset alike, so the check
    /// that switching course sync back on runs decides.
    nonisolated static func coursesReset(
        server: Date?, lastSeen: Date?, takesCourses: Bool
    ) -> (apply: Bool, remember: Date) {
        guard let lastSeen else { return (false, server ?? .distantPast) }
        guard let server else { return (false, lastSeen) }
        return (takesCourses && server > lastSeen, server)
    }

    /// What every full sync keeps: the course reset it read, for the next one to compare, and the
    /// categories whose server data it took (`categoriesTaken`, `hasSynced`).
    static func recordFullSync(coursesReset: Date, taken: Set<String>) {
        Defaults[.lastSeenCoursesResetAt] = coursesReset
        Defaults[.categoriesSyncedOnce].formUnion(taken)
    }

    /// Whether a full sync begun under login `generation` may still write. A sign-out moves the
    /// generation and clears the caches the sync writes, turning Sync course information off
    /// stops the sync from applying the server's state, and a sync that the phone locked under
    /// can resume behind the lock screen, where those caches cannot be opened and read as empty.
    nonisolated static func fullSyncMayWrite(
        startedIn generation: Int, current: Int, cloudSyncEnabled: Bool, protectedDataAvailable: Bool
    ) -> Bool {
        generation == current && cloudSyncEnabled && protectedDataAvailable
    }

    func fullSyncMayWrite(since generation: Int) -> Bool {
        #if os(iOS)
        let protectedDataAvailable = UIApplication.shared.isProtectedDataAvailable
        #else
        let protectedDataAvailable = true
        #endif
        return Self.fullSyncMayWrite(
            startedIn: generation,
            current: authService.loginGeneration,
            cloudSyncEnabled: Defaults[.cloudSyncEnabled],
            protectedDataAvailable: protectedDataAvailable
        )
    }

    /// Takes the server's colours when `colors`, its names when `names`, but not those of the courses
    /// this device has a colour (`holdingColors`) or a name (`holdingNames`) edit queued for, by
    /// Moodle id. Returns whether one changed.
    private func applyCourseOverrides(
        _ overrides: [[String: Any]], coursesArray: [[String: Any]], colors: Bool, names: Bool,
        holdingColors: Set<String>, holdingNames: Set<String>
    ) -> Bool {
        // Build moodleId → courseNo from courses array
        var moodleIdToNo: [String: String] = [:]
        for c in coursesArray {
            guard let mId = c["moodle_id"] as? String ?? (c["moodle_id"] as? Int).map(String.init) else { continue }
            if let courseNo = c["course_no"] as? String, !courseNo.isEmpty {
                moodleIdToNo[mId] = courseNo
            } else if let name = c["course_name"] as? String, let bracketEnd = name.firstIndex(of: "】") {
                let rest = name[name.index(after: bracketEnd)...].trimmingCharacters(in: .whitespaces)
                let code = rest.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
                if !code.isEmpty { moodleIdToNo[mId] = code }
            }
        }
        AppLogger.sync.info("moodleIdToNo: \(moodleIdToNo.count, privacy: .public) entries, overrides: \(overrides.count, privacy: .public)")

        let colorsChanged = colors && TigerDuckTheme.applyColors(
            Self.serverCourseColors(overrides, courseNos: moodleIdToNo, holding: holdingColors)
        )
        let namesBefore = DataCache.shared.loadCourseCustomNames()
        let customNames = names
            ? Self.courseNamesAfterPull(overrides, courseNos: moodleIdToNo, local: namesBefore, holding: holdingNames)
            : namesBefore
        let namesChanged = customNames != namesBefore
        if namesChanged {
            DataCache.shared.saveCourseCustomNames(customNames)
        }
        return colorsChanged || namesChanged
    }

    /// `local` with the server's custom names, language by language; an empty one clears its
    /// language. A course with a name edit queued here (`held`, Moodle ids) keeps all of its own:
    /// the snapshot can predate the edit.
    nonisolated static func courseNamesAfterPull(
        _ overrides: [[String: Any]],
        courseNos: [String: String],
        local: [String: [String: String]],
        holding held: Set<String>
    ) -> [String: [String: String]] {
        var names = local
        for o in overrides {
            guard let mId = o["moodle_id"] as? String ?? (o["moodle_id"] as? Int).map(String.init),
                  !held.contains(mId), let courseNo = courseNos[mId],
                  let serverNames = o["custom_names"] as? [String: String], !serverNames.isEmpty
            else { continue }
            var existing = names[courseNo] ?? [:]
            for (locale, name) in serverNames {
                if name.isEmpty {
                    existing.removeValue(forKey: locale)
                } else {
                    existing[locale] = name
                }
            }
            names[courseNo] = existing.isEmpty ? nil : existing
        }
        return names
    }

    /// The server's course colours in the order to apply them, oldest first: where two courses
    /// share a colour the latest pick keeps it, the same way on every device and every sync. A
    /// course with a colour edit queued here (`held`, Moodle ids) is left out, so it keeps its own
    /// unless the server gives that colour to another course.
    static func serverCourseColors(
        _ overrides: [[String: Any]],
        courseNos: [String: String],
        holding held: Set<String>
    ) -> [(courseNo: String, hex: UInt32)] {
        let rows = overrides.compactMap { o -> (courseNo: String, hex: UInt32, at: Date)? in
            guard let mId = o["moodle_id"] as? String ?? (o["moodle_id"] as? Int).map(String.init),
                  !held.contains(mId), let courseNo = courseNos[mId],
                  let colorHex = o["color_hex"] as? String, !colorHex.isEmpty,
                  let hex = UInt32(colorHex.dropFirst(), radix: 16) else { return nil }
            let at = (o["color_hex_updated_at"] as? String).flatMap {
                TigerDuckDateFormatters.withFractional.date(from: $0)
                    ?? TigerDuckDateFormatters.withoutFractional.date(from: $0)
            } ?? .distantPast
            return (courseNo, hex, at)
        }
        return rows.sorted { ($0.at, $0.courseNo) < ($1.at, $1.courseNo) }.map { ($0.courseNo, $0.hex) }
    }

    func attemptBackendRelogin() async -> Bool {
        guard await authService.reloginToBackend() else { return false }
        pushCoordinator.refreshRegistrationAfterAuth()
        return true
    }

    /// Fire-and-forget override sync to the backend. Local state is already
    /// updated by the ViewModel; this propagates to other devices. The
    /// Assignments sync switch covers these marks. Returns the task that
    /// queues the mark, which ends once it is in the outbox.
    @discardableResult
    func syncAssignmentOverride(moodleId: String, status: String) -> Task<Void, Never>? {
        guard Defaults[.cloudSyncEnabled], Defaults[.syncAssignments] else { return nil }
        AppLogger.sync.debug("override enqueue: \(moodleId, privacy: .private) → \(status, privacy: .public)")
        guard let moodleAssignmentId = Int(moodleId) else { return nil }
        overrideEditGeneration &+= 1
        // Bridge the gap until the op is durably in the outbox; from then
        // on pendingAssignmentOverrideIds() is the conflict-guard signal
        // until the PATCH actually lands on the server.
        pendingOverrides.insert(moodleId)
        let queued = Task { [weak self] in
            guard let self else { return }
            await cloudSyncCoordinator.enqueueAssignmentOverride(
                moodleCourseId: 0,
                moodleAssignmentId: moodleAssignmentId,
                localStatus: status)
            pendingOverrides.remove(moodleId)
        }
        cloudSyncCoordinator.scheduleTick(after: 1)
        revisionPoller.noteActivity()
        return queued
    }

    /// Queues a course's "ignore assignments" setting, which the server's reminders follow. Unlike
    /// a mark it is queued with the Assignments or Courses switch off too, and the outbox holds it
    /// (`CloudSyncCoordinator.sendsCourseIgnores`): the re-enable check compares no course settings
    /// while Courses is off, so a change made then would otherwise be lost to the server's. Returns
    /// the task that queues it, as `syncAssignmentOverride` does.
    @discardableResult
    func syncCourseIgnore(semester: String, courseNo: String, moodleIdNumber: String?, ignore: Bool) -> Task<Void, Never>? {
        guard Defaults[.cloudSyncEnabled] else { return nil }
        // The server keys a course without an idnumber, a hand-added one, by term and number.
        let moodleId = moodleIdNumber.flatMap { $0.isEmpty ? nil : $0 } ?? "\(semester)\(courseNo)"
        let moodleCourseId = DataCache.shared.lookupMoodleCourseId(idnumber: moodleId)
        let key = CourseTombstone.key(semester: semester, courseNo: courseNo)
        overrideEditGeneration &+= 1
        // Covers the course until its op is in the outbox, as for `syncAssignmentOverride`.
        pendingOverrides.insert(key)
        let queued = Task { [weak self] in
            guard let self else { return }
            await cloudSyncCoordinator.enqueueCourseIgnore(
                semester: semester, courseNo: courseNo, moodleId: moodleId,
                moodleCourseId: moodleCourseId, ignore: ignore)
            pendingOverrides.remove(key)
        }
        cloudSyncCoordinator.scheduleTick(after: 1)
        revisionPoller.noteActivity()
        return queued
    }

    /// Queues every course in `keys` as ignored, by the idnumber of the course cached for its term.
    @discardableResult
    func syncCourseIgnores(_ keys: Set<String>) -> [Task<Void, Never>?] {
        keys.sorted().map { key in
            guard let (semester, courseNo) = CourseTombstone.parts(of: key) else { return nil }
            let course = (DataCache.shared.loadCourses(semester: semester)
                + DataCache.shared.loadUserAddedCourses(semester: semester)).first { $0.courseNo == courseNo }
            return syncCourseIgnore(semester: semester, courseNo: courseNo, moodleIdNumber: course?.moodleIdNumber, ignore: true)
        }
    }

    /// Returns the tasks that queue the colour and the name, as `syncAssignmentOverride` does.
    @discardableResult
    func syncCourseOverride(
        moodleCourseId: String,
        colorHex: String? = nil,
        customName: String? = nil,
        locale: String? = nil
    ) -> [Task<Void, Never>?] {
        guard Defaults[.cloudSyncEnabled] else { return [] }
        let semester = CourseSelectionService.currentSemesterCode()
        let queued = [
            colorHex.flatMap {
                cloudSyncCoordinator.enqueueCourseColorOverride(moodleId: moodleCourseId, semester: semester, colorHex: $0)
            },
            customName.flatMap {
                cloudSyncCoordinator.enqueueCourseNameOverride(
                    moodleId: moodleCourseId, semester: semester, customName: $0, locale: locale)
            },
        ]
        cloudSyncCoordinator.scheduleTick(after: 1)
        revisionPoller.noteActivity()
        return queued
    }

    /// Queues the delete of a course hidden here, which the outbox sends until it lands.
    func deleteBackendCourse(courseNo: String, semester: String) {
        guard Defaults[.cloudSyncEnabled] else { return }
        // The reconcile's grace window keeps the course hidden until its delete is in the outbox,
        // where a full sync finds it from then on.
        recentCourseDeletions[courseNo] = Date()
        revisionPoller.noteActivity()
        Task { await cloudSyncCoordinator.deleteCourse(semester: semester, courseNo: courseNo) }
    }

    /// Wipes the backend and only then runs `resetLocally`: a local wipe followed by a
    /// failed DELETE leaves an empty grid over a full server, which merges back as
    /// hand-added rows. `semester` nil wipes every term; the class-table reset passes
    /// its own term so the others survive. The term stays in `resettingSemesters`
    /// across both steps, and the reset is stamped once the DELETE lands, so a snapshot
    /// fetched before then is never reconciled into the term.
    /// - Returns: false when the wipe did not land, so the caller can hold off on a reset
    ///   the next sync would undo by merging the stale server rows back.
    @discardableResult
    func deleteBackendCourses(
        semester: String? = nil,
        thenLocally resetLocally: @MainActor () -> Void = {}
    ) async -> Bool {
        guard Defaults[.cloudSyncEnabled] else {
            resetLocally()
            return true
        }
        if let semester { resettingSemesters.insert(semester) }
        defer { if let semester { resettingSemesters.remove(semester) } }
        do {
            try await pushCoordinator.deleteAllCourses(semester: semester)
            AppLogger.sync.info("deleteBackendCourses ok: \(semester ?? "all", privacy: .public)")
            if let semester { DataCache.shared.recordSemesterReset(semester) }
            // The refetch's upload releases the reset's tombstones, and it usually matches the
            // list sent before the reset.
            pushCoordinator.forgetUploads(semester: semester)
            await cloudSyncCoordinator.discardCourseIgnores(semester: semester)
            await cloudSyncCoordinator.discardCourseDeletes(semester: semester)
            resetLocally()
            return true
        } catch {
            AppLogger.sync.error("deleteBackendCourses failed: \(error, privacy: .private)")
            return false
        }
    }

    /// Uploads one term's course list: a course refresh, a class table edit, the reconcile.
    /// A list the server already took is skipped (`PushCoordinator.uploadCoursesIfChanged`);
    /// `resend` sends it anyway, for a term the server has emptied.
    func uploadCourses(_ courses: [SDCourse], semester: String, forceKeys: [String] = [], resend: Bool = false) {
        // A course added back here: its delete still queued would remove it again.
        if !forceKeys.isEmpty {
            Task { await cloudSyncCoordinator.discardCourseDeletes(courseKeys: Set(forceKeys)) }
        }
        guard CourseUploadPolicy.uploadsCourses else { return }
        let request = Self.courseUploadRequest(courses, semester: semester, forceKeys: forceKeys)
        let generation = authService.loginGeneration
        let coordinator = pushCoordinator
        Task { [weak self] in
            await self?.sendUpload("uploadCourses \(semester)", generation: generation) { isCurrent in
                try await coordinator.uploadCoursesIfChanged(
                    request, semester: semester, resend: resend, isCurrent: isCurrent
                )
            }
        }
    }

    /// Uploads an assignment round's list, which the backend's reminders are built from.
    func uploadAssignments(_ request: PushAPI.AssignmentUploadRequest) {
        guard Defaults[.cloudSyncEnabled] else { return }
        let generation = authService.loginGeneration
        let coordinator = pushCoordinator
        Task { [weak self] in
            await self?.sendUpload("uploadAssignments", generation: generation) { isCurrent in
                try await coordinator.uploadAssignmentsIfChanged(request, isCurrent: isCurrent)
            }
        }
    }

    /// Sends one upload queued under login `generation`, with one relogin on a 401. A sign-out
    /// since drops it: the data is the departing account's, and the session the next one's.
    private func sendUpload(
        _ label: String,
        generation: Int,
        retried: Bool = false,
        _ send: (_ isCurrent: @escaping @MainActor () -> Bool) async throws -> Bool
    ) async {
        let isCurrent: @MainActor () -> Bool = { [weak self] in
            self?.authService.loginGeneration == generation && Defaults[.cloudSyncEnabled]
        }
        guard isCurrent() else { return }
        do {
            let sent = try await send(isCurrent)
            AppLogger.sync.info("\(label, privacy: .public): \(sent ? "sent" : "skipped", privacy: .public)")
        } catch PushAPIError.httpStatus(401, _) where !retried && isCurrent() {
            guard await attemptBackendRelogin() else {
                AppLogger.sync.error("\(label, privacy: .public) failed: 401, relogin failed")
                return
            }
            await sendUpload(label, generation: generation, retried: true, send)
        } catch {
            AppLogger.sync.error("\(label, privacy: .public) failed: \(error, privacy: .private)")
        }
    }

    /// The one builder of a course upload. `colors` go up as `course_overrides`, generated ones
    /// too: an upload only fills a blank `color_hex`, so the first device to upload a course sets
    /// its colour account-wide and the rest take the server's. Picks go through
    /// `syncCourseOverride`, whose PATCH overwrites.
    static func courseUploadRequest(
        _ courses: [SDCourse],
        semester: String,
        forceKeys: [String],
        colors: [String: UInt32] = CourseUploadPolicy.uploadedCourseColors
    ) -> PushAPI.CourseUploadRequest {
        let entries = courses.map { c in
            PushAPI.CourseUploadEntry(
                semester: semester,
                courseNo: c.courseNo,
                courseName: c.courseName,
                courseNameEn: nil,
                moodleId: c.moodleIdNumber,
                credits: c.credits > 0 ? c.credits : nil,
                classroom: c.classroom.isEmpty ? nil : c.classroom,
                instructors: c.instructor.isEmpty ? [] : [c.instructor],
                scheduleJson: c.schedule.isEmpty ? nil : Dictionary(uniqueKeysWithValues: c.schedule.map { ("\($0.key)", $0.value) }),
                classroomMap: c.classroomMap.isEmpty ? nil : c.classroomMap
            )
        }
        let overrides = courses.compactMap { c -> PushAPI.CourseOverrideUploadEntry? in
            guard let hex = colors[c.courseNo] else { return nil }
            return PushAPI.CourseOverrideUploadEntry(
                courseKey: CourseTombstone.serverKey(semester: semester, courseNo: c.courseNo),
                colorHex: String(format: "#%06X", hex)
            )
        }
        return PushAPI.CourseUploadRequest(courses: entries, courseOverrides: overrides, forceKeys: forceKeys)
    }
}

/// Runs one full sync at a time. Callers on the main actor interleave at its awaits and would
/// clobber each other's cache read-modify-writes, or bring back a dismissed conflict alert.
@MainActor
final class FullSyncGate {
    private(set) var isRunning = false
    private var followUpWaiters: [CheckedContinuation<FullSyncOutcome, Never>] = []

    var queuedFollowUps: Int { followUpWaiters.count }

    /// Runs `body` unless a run is in flight. Then a call with `followUp` waits for one more run
    /// that starts after the current one, shared by every call that asked meanwhile, and returns
    /// its outcome; one without returns `.skipped` at once. `mayFollow` is checked before each
    /// follow-up. A call that runs `body` returns the outcome of its own run.
    func run(followUp: Bool, mayFollow: () -> Bool, _ body: () async -> FullSyncOutcome) async -> FullSyncOutcome {
        guard !isRunning else {
            guard followUp else { return .skipped }
            return await withCheckedContinuation { followUpWaiters.append($0) }
        }
        isRunning = true
        let outcome = await body()
        while !followUpWaiters.isEmpty {
            let waiters = followUpWaiters
            followUpWaiters = []
            let followed = mayFollow() ? await body() : .skipped
            for waiter in waiters { waiter.resume(returning: followed) }
        }
        isRunning = false
        return outcome
    }
}

/// When this device may upload its course list.
///
/// iPhone and iPad follow "Sync course information" alone: class reminders are built
/// from what they upload, so it is more than sync for them. A Mac takes no push, so
/// its upload serves cross-device sync and nothing else, and it also follows the
/// "Synced content" switches: "All courses" for the list, "Course colours" for colours.
enum CourseUploadPolicy {
    static var uploadsCourses: Bool {
        guard Defaults[.cloudSyncEnabled] else { return false }
        #if os(macOS)
        return Defaults[.syncCourses]
        #else
        return true
        #endif
    }

    static var uploadsCourseColors: Bool {
        #if os(macOS)
        return uploadsCourses && Defaults[.syncCourseColors]
        #else
        return uploadsCourses
        #endif
    }

    static var uploadedCourseColors: [String: UInt32] {
        uploadsCourseColors ? TigerDuckTheme.courseColorMap : [:]
    }
}
