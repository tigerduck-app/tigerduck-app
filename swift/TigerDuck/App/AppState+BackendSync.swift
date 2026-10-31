import SwiftUI
import SwiftData
import Defaults
import os

extension AppState {

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
            await self.runFullSync(retried: false)
        }
    }

    private func runFullSync(retried: Bool) async -> FullSyncOutcome {
        let ticket = authService.session.ticket
        await authService.ensureBackendSignedIn()
        guard await authTokenManager.isLoggedIn, fullSyncMayWrite(since: ticket) else { return .skipped }
        await retryUnsentEdits()
        do {
            #if DEBUG
            try await ServerFailureSimulator.shared.check(.backend)
            #endif
            let preFetchInFlight = await cloudSyncCoordinator.pendingAssignmentOverrideIds()
                .union(cloudSyncCoordinator.pendingCourseIgnoreKeys())
            let preFetchProtected = preFetchInFlight.union(pendingOverrides)
            let preFetchCourseOverrides = await cloudSyncCoordinator.pendingCourseOverrides()
            let editGenerationAtFetch = overrideEditGeneration
            let fetchedAt = Date()
            #if os(iOS)
            let settingsLinksBeforeFetch = NotificationSettingsPushQueue.finishedLinks
            #endif
            let (json, fetchedDeletes) = try await cloudSyncCoordinator.courseDeletes(around: {
                try await pushCoordinator.fetchFullSync()
            })
            var courseDeletes = fetchedDeletes
            guard fullSyncMayWrite(since: ticket) else { return .skipped }
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

            let inFlightOverrides = await cloudSyncCoordinator.pendingAssignmentOverrideIds()
                .union(cloudSyncCoordinator.pendingCourseIgnoreKeys())
            guard fullSyncMayWrite(since: ticket) else { return .skipped }
            let takesCourses = Self.switchedOnCategories().contains("courses")
                && !Defaults[.pendingConflictCategories].contains("courses")
            let reset = Self.coursesReset(
                server: Self.backendDate(json["courses_reset_at"]), lastSeen: Defaults[.lastSeenCoursesResetAt],
                takesCourses: takesCourses
            )
            if takesCourses {
                guard let settled = await settleQueuedCourseEdits(
                    deleting: courseDeletes, reset: reset, ticket: ticket
                ) else { return .skipped }
                courseDeletes = settled
                changed = reset.apply || changed
            }
            let courseAdds = await cloudSyncCoordinator.courseAddKeys(unlandedAt: fetchedAt)
            guard fullSyncMayWrite(since: ticket) else { return .skipped }
            let protectedOverrides = preFetchProtected
                .union(pendingOverrides)
                .union(inFlightOverrides)

            let pendingConflicts = Defaults[.pendingConflictCategories]
            let marksLeftFor = Self.reasonToLeaveMarks(
                syncsMarks: syncsMarks && Defaults[.syncAssignments],
                conflictCheckPending: pendingConflicts.contains("assignments"),
                uploadedLocalMarks: isMigrating,
                editedDuringFetch: overrideEditGeneration != editGenerationAtFetch
            )
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
                let held = cloudSyncCoordinator.courseOverridesToHold(since: preFetchCourseOverrides)
                changed = applyCourseOverrides(
                    courseOverrides, coursesArray: coursesArray, colors: takesColors, names: takesNames,
                    holdingColors: held.colors, holdingNames: held.names
                ) || changed
            }

            if let holidayRows = json["holiday_overrides"] as? [[String: Any]] {
                let optedIn = Set(
                    holidayRows.compactMap { row -> Int? in
                        guard row["notify"] as? Bool == true else { return nil }
                        return row["holiday_id"] as? Int
                    }
                )
                changed = AcademicCalendarStore.shared.applySyncedOverrides(optedIn, fetchedAt: fetchedAt) || changed
            }

            let tombstoneArray = json["course_tombstones"] as? [[String: Any]] ?? []
            Self.recordFullSync(coursesReset: reset.remember, taken: taken)

            if taken.contains("courses") {
                changed = reconcileCourses(
                    serverRows: coursesArray, tombstones: tombstoneArray, deleting: courseDeletes,
                    adding: courseAdds, fetchedAt: fetchedAt
                ) || changed
            } else if pendingConflicts.contains("courses") {
                AppLogger.sync.info("[syncOverrides] skipping course sync — conflict check pending")
            }
            AppServiceBridge.answerRosterRequests(in: json, authService: authService)

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
            reconcileNotificationSettings(
                snapshot: NotificationSettingsSync.documentSource(fromSnapshot: json),
                linksBeforeSnapshot: settingsLinksBeforeFetch
            )
            #endif
            return .synced
        } catch {
            guard !Self.isCancellation(error), fullSyncMayWrite(since: ticket) else { return .skipped }
            ServerStatusTracker.shared.noteSyncResult(false)
            recordSyncSource(.local)
            var outcome = FullSyncOutcome.failed
            if case PushAPIError.httpStatus(401, _, let sent) = error, !retried {
                let reloginOk = await attemptBackendRelogin(replacing: sent?.value)
                if reloginOk {
                    AppLogger.sync.info("auto-relogin succeeded, retrying sync")
                    try? await Task.sleep(for: .milliseconds(500))
                    guard fullSyncMayWrite(since: ticket) else { return .skipped }
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

    func retryUnsentEdits() async {
        retryUnacknowledgedHolidayOverrides()
        #if os(iOS)
        retryUnacknowledgedNotificationSettings()
        #endif
        await cloudSyncCoordinator.requeueParkedMarks()
    }

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

    nonisolated static func uploadsLocalMarksAsFirstSync(
        syncedBefore: Bool,
        serverHasMarks: Bool,
        localHasMarks: Bool
    ) -> Bool {
        !syncedBefore && !serverHasMarks && localHasMarks
    }

    nonisolated static func mergedMarks(
        server: Set<String>,
        local: Set<String>,
        protected: Set<String>
    ) -> Set<String> {
        server.subtracting(protected).union(local.intersection(protected))
    }

    nonisolated static func assignmentMarksToClear(server: Set<String>, local: Set<String>) -> Set<String> {
        server.subtracting(local)
    }

    nonisolated struct ServerIgnoredCourse: Equatable {
        let semester: String
        let courseNo: String
        let moodleId: String?
        let moodleCourseId: Int?

        var key: String { CourseTombstone.key(semester: semester, courseNo: courseNo) }
    }

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

    nonisolated static func courseIgnoresToClear(
        server: [ServerIgnoredCourse],
        local: Set<String>
    ) -> [ServerIgnoredCourse] {
        server.filter { !local.contains($0.key) }
    }

    nonisolated static func serverDecidedCourses(_ overrides: [[String: Any]]) -> Set<String> {
        Set(overrides.compactMap { row in
            guard row["ignore_assignments"] as? Bool == true || row["ignore_assignments_updated_at"] is String,
                  let semester = row["semester"] as? String, !semester.isEmpty,
                  let courseNo = row["course_no"] as? String, !courseNo.isEmpty
            else { return nil }
            return CourseTombstone.key(semester: semester, courseNo: courseNo)
        })
    }

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

    nonisolated static func coursesReset(
        server: Date?, lastSeen: Date?, takesCourses: Bool
    ) -> (apply: Bool, remember: Date) {
        guard let lastSeen else { return (false, server ?? .distantPast) }
        guard let server else { return (false, lastSeen) }
        return (takesCourses && server > lastSeen, server)
    }

    static func recordFullSync(coursesReset: Date, taken: Set<String>) {
        Defaults[.lastSeenCoursesResetAt] = coursesReset
        Defaults[.categoriesSyncedOnce].formUnion(taken)
    }

    nonisolated static func fullSyncMayWrite(
        signedOutSince: Bool, cloudSyncEnabled: Bool, protectedDataAvailable: Bool
    ) -> Bool {
        !signedOutSince && cloudSyncEnabled && protectedDataAvailable
    }

    func fullSyncMayWrite(since ticket: AccountSession.Ticket) -> Bool {
        #if os(iOS)
        let protectedDataAvailable = UIApplication.shared.isProtectedDataAvailable
        #else
        let protectedDataAvailable = true
        #endif
        return Self.fullSyncMayWrite(
            signedOutSince: !authService.session.isCurrent(ticket),
            cloudSyncEnabled: Defaults[.cloudSyncEnabled],
            protectedDataAvailable: protectedDataAvailable
        )
    }

    private func applyCourseOverrides(
        _ overrides: [[String: Any]], coursesArray: [[String: Any]], colors: Bool, names: Bool,
        holdingColors: Set<String>, holdingNames: Set<String>
    ) -> Bool {
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

    /// `refused` is the access token the request that got the 401 sent.
    func attemptBackendRelogin(replacing refused: String?) async -> Bool {
        guard await authService.reloginToBackend(replacing: refused) else { return false }
        pushCoordinator.refreshRegistrationAfterAuth()
        return true
    }

    @discardableResult
    func syncAssignmentOverride(moodleId: String, status: String) -> Task<Void, Never>? {
        guard Defaults[.cloudSyncEnabled], Defaults[.syncAssignments] else { return nil }
        AppLogger.sync.debug("override enqueue: \(moodleId, privacy: .private) → \(status, privacy: .public)")
        guard let moodleAssignmentId = Int(moodleId) else { return nil }
        overrideEditGeneration &+= 1
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

    @discardableResult
    func syncCourseIgnore(semester: String, courseNo: String, moodleIdNumber: String?, ignore: Bool) -> Task<Void, Never>? {
        guard Defaults[.cloudSyncEnabled] else { return nil }
        let moodleId = moodleIdNumber.flatMap { $0.isEmpty ? nil : $0 } ?? "\(semester)\(courseNo)"
        let moodleCourseId = DataCache.shared.lookupMoodleCourseId(idnumber: moodleId)
        let key = CourseTombstone.key(semester: semester, courseNo: courseNo)
        overrideEditGeneration &+= 1
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

    @discardableResult
    func syncCourseIgnores(_ keys: Set<String>) -> [Task<Void, Never>?] {
        keys.sorted().map { key in
            guard let (semester, courseNo) = CourseTombstone.parts(of: key) else { return nil }
            let course = (DataCache.shared.loadCourses(semester: semester)
                + DataCache.shared.loadUserAddedCourses(semester: semester)).first { $0.courseNo == courseNo }
            return syncCourseIgnore(semester: semester, courseNo: courseNo, moodleIdNumber: course?.moodleIdNumber, ignore: true)
        }
    }

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

    func deleteBackendCourse(courseNo: String, semester: String) {
        guard Defaults[.cloudSyncEnabled] else { return }
        let hiddenAt = Date()
        recentCourseDeletions[courseNo] = hiddenAt
        revisionPoller.noteActivity()
        Task { await cloudSyncCoordinator.deleteCourse(semester: semester, courseNo: courseNo, at: hiddenAt) }
    }

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
            try await Self.resetCourses(semester: semester, on: cloudSyncCoordinator, onServer: { [pushCoordinator] in
                try await pushCoordinator.deleteAllCourses(semester: semester)
                AppLogger.sync.info("deleteBackendCourses ok: \(semester ?? "all", privacy: .public)")
                if let semester { DataCache.shared.recordSemesterReset(semester) }
                pushCoordinator.forgetUploads(semester: semester)
            }, thenLocally: resetLocally)
            return true
        } catch {
            AppLogger.sync.error("deleteBackendCourses failed: \(error, privacy: .private)")
            return false
        }
    }

    /// Resets the courses on the server, then clears them here and drops the deletes queued until
    /// that moment, so a hide made during the request is gone from both and a later one kept in both.
    static func resetCourses(
        semester: String?, on coordinator: CloudSyncCoordinator,
        onServer reset: () async throws -> Void, thenLocally resetLocally: () -> Void
    ) async throws {
        try await reset()
        let resetAt = Date()
        resetLocally()
        await coordinator.discardCourseIgnores(semester: semester)
        await coordinator.discardCourseDeletes(semester: semester, madeBefore: resetAt)
    }

    func uploadCourses(
        _ courses: [SDCourse], semester: String, forceKeys: [String] = [], asRoster: Bool = false, resend: Bool = false
    ) {
        if !forceKeys.isEmpty {
            let addedAt = Date()
            Task { await cloudSyncCoordinator.discardCourseDeletes(courseKeys: Set(forceKeys), madeBefore: addedAt) }
        }
        guard CourseUploadPolicy.uploadsCourses else { return }
        guard forceKeys.isEmpty else {
            let prefix = CourseTombstone.serverKey(semester: semester, courseNo: "")
            for key in forceKeys where key.hasPrefix(prefix) {
                cloudSyncCoordinator.addCourse(semester: semester, courseNo: String(key.dropFirst(prefix.count)))
            }
            return
        }
        let request = Self.courseUploadRequest(
            courses, semester: semester, forceKeys: forceKeys, rosterTerms: asRoster ? [semester] : nil
        )
        let ticket = authService.session.ticket
        let coordinator = pushCoordinator
        Task { [weak self] in
            await self?.sendUpload("uploadCourses \(semester)", ticket: ticket) { isCurrent in
                try await coordinator.uploadCoursesIfChanged(
                    request, semester: semester, resend: resend, isCurrent: isCurrent
                )
            }
        }
    }

    /// The added course alone: sent with its stamp, the backend files every other course an upload
    /// lists as the school's roster.
    static func addedCourseUpload(
        semester: String, courseNo: String, cache: DataCache = .shared,
        colors: [String: UInt32] = CourseUploadPolicy.uploadedCourseColors
    ) -> PushAPI.CourseUploadRequest? {
        let shown = CanonicalCourseProvider(cache: cache).currentCourses(semester: semester)
        guard let course = shown.first(where: { $0.courseNo == courseNo }) else { return nil }
        return courseUploadRequest(
            [course], semester: semester, forceKeys: [CourseTombstone.serverKey(semester: semester, courseNo: courseNo)],
            colors: colors
        )
    }

    func uploadAssignments(_ request: PushAPI.AssignmentUploadRequest) {
        guard Defaults[.cloudSyncEnabled] else { return }
        let ticket = authService.session.ticket
        let coordinator = pushCoordinator
        Task { [weak self] in
            await self?.sendUpload("uploadAssignments", ticket: ticket) { isCurrent in
                try await coordinator.uploadAssignmentsIfChanged(request, isCurrent: isCurrent)
            }
        }
    }

    private func sendUpload(
        _ label: String,
        ticket: AccountSession.Ticket,
        retried: Bool = false,
        _ send: (_ isCurrent: @escaping @MainActor () -> Bool) async throws -> Bool
    ) async {
        let isCurrent: @MainActor () -> Bool = { [weak self] in
            self?.authService.session.isCurrent(ticket) == true && Defaults[.cloudSyncEnabled]
        }
        guard isCurrent() else { return }
        do {
            let sent = try await send(isCurrent)
            AppLogger.sync.info("\(label, privacy: .public): \(sent ? "sent" : "skipped", privacy: .public)")
        } catch PushAPIError.httpStatus(401, _, let sent) where !retried && isCurrent() {
            guard await attemptBackendRelogin(replacing: sent?.value) else {
                AppLogger.sync.error("\(label, privacy: .public) failed: 401, relogin failed")
                return
            }
            await sendUpload(label, ticket: ticket, retried: true, send)
        } catch {
            AppLogger.sync.error("\(label, privacy: .public) failed: \(error, privacy: .private)")
        }
    }

    static func courseUploadRequest(
        _ courses: [SDCourse],
        semester: String,
        forceKeys: [String],
        rosterTerms: [String]? = nil,
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
        return PushAPI.CourseUploadRequest(
            courses: entries, courseOverrides: overrides, forceKeys: forceKeys, rosterTerms: rosterTerms
        )
    }
}

@MainActor
final class FullSyncGate {
    private(set) var isRunning = false
    private var queued: [Int: CheckedContinuation<FullSyncOutcome, Never>] = [:]
    private var following: [Int: CheckedContinuation<FullSyncOutcome, Never>] = [:]
    private var runningFollowUp: Task<Void, Never>?
    private var lastTicket = 0

    var queuedFollowUps: Int { queued.count }

    func run(
        followUp: Bool, mayFollow: @escaping () -> Bool, _ body: @escaping () async -> FullSyncOutcome
    ) async -> FullSyncOutcome {
        guard !isRunning else {
            guard followUp else { return .skipped }
            return await waitForFollowUp()
        }
        isRunning = true
        let outcome = await body()
        follow(mayFollow: mayFollow, body)
        return outcome
    }

    private func waitForFollowUp() async -> FullSyncOutcome {
        lastTicket += 1
        let ticket = lastTicket
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiter in
                if Task.isCancelled { waiter.resume(returning: .skipped) } else { queued[ticket] = waiter }
            }
        } onCancel: {
            Task { @MainActor in self.giveUp(ticket) }
        }
    }

    private func giveUp(_ ticket: Int) {
        if let waiter = queued.removeValue(forKey: ticket) {
            waiter.resume(returning: .skipped)
        } else if let waiter = following.removeValue(forKey: ticket) {
            waiter.resume(returning: .skipped)
            if following.isEmpty { runningFollowUp?.cancel() }
        }
    }

    private func follow(mayFollow: @escaping () -> Bool, _ body: @escaping () async -> FullSyncOutcome) {
        guard !queued.isEmpty, mayFollow() else {
            for waiter in queued.values { waiter.resume(returning: .skipped) }
            queued = [:]
            isRunning = false
            return
        }
        following = queued
        queued = [:]
        runningFollowUp = Task {
            let outcome: FullSyncOutcome = if Task.isCancelled { .skipped } else { await body() }
            for waiter in following.values { waiter.resume(returning: outcome) }
            following = [:]
            follow(mayFollow: mayFollow, body)
        }
    }
}

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
