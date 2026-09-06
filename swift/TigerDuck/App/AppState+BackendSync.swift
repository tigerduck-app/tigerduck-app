// Override synchronisation with the TigerDuck backend — split out of
// AppState.swift.
//
// The assignment LIST always comes from Moodle-direct; what syncs here is
// the user's own marks on top of it (done/ignored, course colour and name
// overrides, manual courses). Pull is `syncOverridesFromBackend`, push is
// the `sync*Override` / `upload*` / `delete*` family.

import SwiftUI
import SwiftData
import Defaults
import os

extension AppState {

    /// Fetch override state (done/ignored) from the backend and apply it
    /// locally. The assignment LIST comes from Moodle-direct (proven
    /// semester filtering); this only syncs the user's swipe marks.
    func syncOverridesFromBackend(retried: Bool = false) async {
        guard Defaults[.cloudSyncEnabled] else { return }
        // Reentrancy guard set before the first await so two MainActor callers
        // can't both pass. The 401-retry (retried: true) is a controlled
        // re-entry from our own catch, so it bypasses the guard and reuses the
        // flag the outer call still holds.
        if !retried {
            guard !isSyncingOverrides else {
                AppLogger.sync.info("[syncOverrides] skipped — already in flight")
                return
            }
            isSyncingOverrides = true
        }
        defer { if !retried { isSyncingOverrides = false } }
        guard await authTokenManager.isLoggedIn else { return }
        do {
            #if DEBUG
            try await ServerFailureSimulator.shared.check(.backend)
            #endif
            // Sample the pending set on both sides of the fetch: an edit whose
            // PATCH fully lands while the fetch is in flight leaves both the
            // marker set and the outbox before the (stale) payload arrives.
            let preFetchInFlight = await cloudSyncCoordinator.pendingAssignmentOverrideIds()
            let preFetchProtected = preFetchInFlight.union(pendingOverrides)
            let editGenerationAtFetch = overrideEditGeneration
            let json = try await pushCoordinator.fetchFullSync()
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

            // First-time migration: upload local overrides if server has none.
            // Only skip the conflict-detection block — course overrides,
            // hard-delete detection, and the dataDidUpdate notification must
            // still run so the first sync after migration picks up colour /
            // custom-name changes and cross-device deletions.
            let localArchivedIds = DataCache.shared.loadArchivedAssignmentIds()
            let localCompletedIds = DataCache.shared.loadLocallyCompletedAssignmentIds()
            let isMigrating = serverArchivedIds.isEmpty && serverCompletedIds.isEmpty
                && (!localArchivedIds.isEmpty || !localCompletedIds.isEmpty)
            if isMigrating {
                for id in localArchivedIds { syncAssignmentOverride(moodleId: id, status: "archived") }
                for id in localCompletedIds { syncAssignmentOverride(moodleId: id, status: "locally_completed") }
            }

            // Ops still queued in the outbox are local edits in flight to the
            // server — differences against the (possibly stale) pull payload
            // are not cross-device conflicts.
            let inFlightOverrides = await cloudSyncCoordinator.pendingAssignmentOverrideIds()
            let protectedOverrides = preFetchProtected
                .union(pendingOverrides)
                .union(inFlightOverrides)

            let pendingConflicts = Defaults[.pendingConflictCategories]
            if pendingConflicts.contains("assignments") {
                AppLogger.sync.info("[syncOverrides] skipping assignment overrides — conflict check pending")
            } else if isMigrating {
                // Local overrides were just uploaded above; nothing to
                // reconcile until the server echoes them back.
            } else if overrideEditGeneration != editGenerationAtFetch {
                // An edit landed while the pull was in flight; the payload
                // predates it. Defer to the next pull (the drain's revision
                // bump re-triggers one) instead of comparing stale state.
                AppLogger.sync.info("[syncOverrides] skipping assignment overrides — local edit during fetch")
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
                var safeArchived = serverArchivedIds.filter { !conflictIds.contains($0) }
                    .union(DataCache.shared.loadArchivedAssignmentIds().filter { protectedOverrides.contains($0) })
                var safeCompleted = serverCompletedIds.filter { !conflictIds.contains($0) }
                    .union(DataCache.shared.loadLocallyCompletedAssignmentIds().filter { protectedOverrides.contains($0) })
                // Preserve local state for conflicting items until user resolves
                for c in conflicts {
                    switch c.local {
                    case "ignored", "archived": safeArchived.insert(c.id)
                    case "locally_completed": safeCompleted.insert(c.id)
                    default: break
                    }
                }
                DataCache.shared.replaceArchivedAssignmentIds(safeArchived)
                DataCache.shared.replaceLocallyCompletedAssignmentIds(safeCompleted)

                AppLogger.sync.info("applied: \(safeArchived.count, privacy: .public) archived, \(safeCompleted.count, privacy: .public) completed, \(conflicts.count, privacy: .public) conflicts pending")

                if !conflicts.isEmpty {
                    await MainActor.run {
                        syncConflicts = conflicts.map { SyncConflictItem(id: $0.id, kind: $0.kind, label: $0.label, localStatus: $0.local, serverStatus: $0.server) }
                        pendingSyncServerArchived = serverArchivedIds
                        pendingSyncServerCompleted = serverCompletedIds
                    }
                }
            }

            let coursesArray = json["courses"] as? [[String: Any]] ?? []
            let courseOverrides = json["course_overrides"] as? [[String: Any]] ?? []
            if pendingConflicts.contains("course_colors") || pendingConflicts.contains("course_names") {
                AppLogger.sync.info("[syncOverrides] skipping course overrides — conflict check pending")
            } else if !courseOverrides.isEmpty {
                applyCourseOverrides(courseOverrides, coursesArray: coursesArray)
            }

            // Conflict resolution: detect reset + process tombstones
            let coursesResetAtStr = json["courses_reset_at"] as? String
            let coursesResetAt = coursesResetAtStr.flatMap { ISO8601DateFormatter().date(from: $0) }
            let tombstoneArray = json["course_tombstones"] as? [[String: Any]] ?? []
            let lastCourseSyncAt = UserDefaults.standard.object(forKey: "lastCourseSyncAt") as? Date

            if let resetAt = coursesResetAt, let syncAt = lastCourseSyncAt, resetAt > syncAt {
                DataCache.shared.saveUserAddedCourses([])
                DataCache.shared.saveDeletedCourseNos([])
                AppLogger.sync.info("[sync] courses reset detected (reset=\(resetAt, privacy: .public) > lastSync=\(syncAt, privacy: .public)), wiped local state")
            }

            var tombstonedNos = Set<String>()
            for t in tombstoneArray {
                if let courseNo = t["course_no"] as? String {
                    tombstonedNos.insert(courseNo)
                }
            }

            if pendingConflicts.contains("courses") {
                AppLogger.sync.info("[syncOverrides] skipping course sync — conflict check pending")
            } else if Defaults[.syncCourses], !coursesArray.isEmpty {
                let serverCourseNos = Set(coursesArray.compactMap { $0["course_no"] as? String })
                var deletedNos = Set(DataCache.shared.loadDeletedCourseNos())
                let semester = CourseSelectionService.currentSemesterCode()
                let localCourses = DataCache.shared.loadCourses(semester: semester)
                let localCourseNos = Set(localCourses.map(\.courseNo))
                AppLogger.sync.info("[sync-debug] semester=\(semester, privacy: .public) serverCourses=\(serverCourseNos.sorted(), privacy: .public) localCourses=\(localCourseNos.sorted(), privacy: .public) deletedNos=\(deletedNos.sorted(), privacy: .public)")
                let serverSemesters = Set(coursesArray.compactMap { $0["semester"] as? String })
                AppLogger.sync.info("[sync-debug] server course semesters=\(serverSemesters.sorted(), privacy: .public)")
                var changed = false

                // A local course NOT in server courses → deleted on another device
                for courseNo in localCourseNos where !serverCourseNos.contains(courseNo) && !deletedNos.contains(courseNo) {
                    deletedNos.insert(courseNo)
                    changed = true
                    AppLogger.sync.info("[sync-debug] marking \(courseNo, privacy: .public) as deleted (local-only, not in server)")
                }

                // Apply tombstones: courses explicitly deleted on another device
                for courseNo in tombstonedNos where !serverCourseNos.contains(courseNo) && !deletedNos.contains(courseNo) {
                    deletedNos.insert(courseNo)
                    changed = true
                    AppLogger.sync.info("[sync-debug] marking \(courseNo, privacy: .public) as deleted (tombstone)")
                }

                // Bug fix: also remove userAddedCourses not present on server
                var userAddedForDelete = DataCache.shared.loadUserAddedCourses()
                let userAddedBeforeDelete = userAddedForDelete.count
                userAddedForDelete.removeAll { !serverCourseNos.contains($0.courseNo) }
                if userAddedForDelete.count != userAddedBeforeDelete {
                    DataCache.shared.saveUserAddedCourses(userAddedForDelete)
                    AppLogger.sync.info("[sync-debug] removed \(userAddedBeforeDelete - userAddedForDelete.count, privacy: .public) userAdded courses not on server")
                }

                // A courseNo in deletedNos that IS in server courses → the
                // course is back on the server, so treat it as un-deleted —
                // EXCEPT when the user just deleted it locally and the backend
                // DELETE may still be in flight. Honour a short grace window so
                // the course doesn't flap back into the timetable before the
                // delete lands. Expire stale grace entries as we go.
                let graceNow = Date()
                recentCourseDeletions = recentCourseDeletions.filter {
                    graceNow.timeIntervalSince($0.value) < Self.courseDeleteGraceInterval
                }
                for courseNo in deletedNos where serverCourseNos.contains(courseNo) {
                    if recentCourseDeletions[courseNo] != nil {
                        AppLogger.sync.info("[sync-debug] keeping \(courseNo, privacy: .public) deleted (backend delete still in flight)")
                        continue
                    }
                    deletedNos.remove(courseNo)
                    changed = true
                    AppLogger.sync.info("[sync-debug] un-deleting \(courseNo, privacy: .public) (back in server courses)")
                }

                if changed {
                    DataCache.shared.saveDeletedCourseNos(Array(deletedNos))
                    let filtered = localCourses.filter { !deletedNos.contains($0.courseNo) }
                    if filtered.count != localCourses.count {
                        DataCache.shared.saveCourses(filtered, semester: semester)
                    }
                }

                // Merge courses that exist on the server but not locally.
                // Save into userAddedCourses so they survive portal refreshes
                // (portal fetch overwrites the main course cache).
                let localNamesByNo = Dictionary(localCourses.map { ($0.courseNo, $0.courseName) }, uniquingKeysWith: { first, _ in first })
                let userAddedNos = Set(DataCache.shared.loadUserAddedCourses().map(\.courseNo))
                let allLocalNos = localCourseNos.union(userAddedNos)
                let missingLocally = serverCourseNos.subtracting(allLocalNos).subtracting(deletedNos)
                AppLogger.sync.info("[sync-debug] missingLocally=\(missingLocally.sorted(), privacy: .public) (after subtracting deletedNos=\(deletedNos.sorted(), privacy: .public) userAddedNos=\(userAddedNos.sorted(), privacy: .public))")

                var userAdded = DataCache.shared.loadUserAddedCourses()
                var userAddedChanged = false

                // Update existing user-added courses with server data (e.g. schedule)
                for (idx, existing) in userAdded.enumerated() {
                    guard existing.schedule.isEmpty,
                          let courseDict = coursesArray.first(where: { $0["course_no"] as? String == existing.courseNo }),
                          let schedJson = courseDict["schedule_json"] as? [String: [String]],
                          !schedJson.isEmpty else { continue }
                    var schedule: [Int: [String]] = [:]
                    for (key, val) in schedJson {
                        if let weekday = Int(key) { schedule[weekday] = val }
                    }
                    let cmap = courseDict["classroom_map"] as? [String: String] ?? [:]
                    let instructors = (courseDict["instructors"] as? [String])?.joined(separator: ", ") ?? existing.instructor
                    userAdded[idx] = SDCourse(
                        courseNo: existing.courseNo,
                        courseName: localNamesByNo[existing.courseNo] ?? courseDict["course_name"] as? String ?? existing.courseName,
                        instructor: instructors,
                        credits: Int(courseDict["credits"] as? Double ?? Double(existing.credits)),
                        classroom: courseDict["classroom"] as? String ?? existing.classroom,
                        enrolledCount: courseDict["enrolled_count"] as? Int ?? existing.enrolledCount,
                        maxCount: courseDict["max_count"] as? Int ?? existing.maxCount,
                        schedule: schedule,
                        moodleIdNumber: courseDict["moodle_id"] as? String ?? existing.moodleIdNumber,
                        semester: existing.semester,
                        classroomMap: cmap
                    )
                    userAddedChanged = true
                    AppLogger.sync.info("[sync-debug] updated userAdded \(existing.courseNo, privacy: .public) with schedule from server")
                }

                // Add new courses from server
                if !missingLocally.isEmpty {
                    let existingNos = Set(userAdded.map(\.courseNo))
                    for courseDict in coursesArray {
                        guard let courseNo = courseDict["course_no"] as? String,
                              missingLocally.contains(courseNo),
                              !existingNos.contains(courseNo),
                              let courseSemester = courseDict["semester"] as? String,
                              courseSemester == semester else {
                            let courseNo = courseDict["course_no"] as? String ?? "<nil>"
                            let courseSem = courseDict["semester"] as? String ?? "<nil>"
                            if missingLocally.contains(courseNo) {
                                AppLogger.sync.info("[sync-debug] SKIP merge \(courseNo, privacy: .public): courseSemester=\(courseSem, privacy: .public) vs local=\(semester, privacy: .public) alreadyInUserAdded=\(existingNos.contains(courseNo), privacy: .public)")
                            }
                            continue
                        }
                        let instructors = (courseDict["instructors"] as? [String])?.joined(separator: ", ") ?? ""
                        var schedule: [Int: [String]] = [:]
                        if let schedJson = courseDict["schedule_json"] as? [String: [String]] {
                            for (key, val) in schedJson {
                                if let weekday = Int(key) { schedule[weekday] = val }
                            }
                        }
                        let cmap = courseDict["classroom_map"] as? [String: String] ?? [:]
                        let course = SDCourse(
                            courseNo: courseNo,
                            courseName: localNamesByNo[courseNo] ?? courseDict["course_name"] as? String ?? courseNo,
                            instructor: instructors,
                            credits: Int(courseDict["credits"] as? Double ?? 0),
                            classroom: courseDict["classroom"] as? String ?? "",
                            enrolledCount: courseDict["enrolled_count"] as? Int ?? 0,
                            maxCount: courseDict["max_count"] as? Int ?? 0,
                            schedule: schedule,
                            moodleIdNumber: courseDict["moodle_id"] as? String,
                            semester: semester,
                            classroomMap: cmap
                        )
                        userAdded.append(course)
                        userAddedChanged = true
                        AppLogger.sync.info("[sync-debug] merged course from server into userAdded: \(courseNo, privacy: .public)")
                    }
                }

                if userAddedChanged {
                    DataCache.shared.saveUserAddedCourses(userAdded)
                    let lang = LanguageManager.resolvedCourseApiLanguage(appLanguage: Defaults[.appLanguage])
                    let needsLookup = userAdded.filter { localNamesByNo[$0.courseNo] == nil }
                    if !needsLookup.isEmpty {
                        // SDCourse is @MainActor-isolated (@Model), so snapshot
                        // the fields we need into Sendable value types here on
                        // the main actor. The detached task does only the
                        // network lookups, then hops back to the MainActor to
                        // touch SDCourse / DataCache — reading or constructing
                        // an @Model off-main is a data race.
                        struct LookupSeed: Sendable {
                            let courseNo: String
                            let credits: Int
                            let classroom: String
                            let enrolledCount: Int
                            let maxCount: Int
                            let schedule: [Int: [String]]
                            let moodleIdNumber: String?
                            let semester: String
                            let classroomMap: [String: String]
                        }
                        let seeds = needsLookup.map {
                            LookupSeed(
                                courseNo: $0.courseNo, credits: $0.credits,
                                classroom: $0.classroom, enrolledCount: $0.enrolledCount,
                                maxCount: $0.maxCount, schedule: $0.schedule,
                                moodleIdNumber: $0.moodleIdNumber, semester: $0.semester,
                                classroomMap: $0.classroomMap)
                        }
                        Task.detached {
                            var resolved: [(seed: LookupSeed, name: String, instructor: String, classroom: String)] = []
                            for seed in seeds {
                                guard let results = try? await CourseLookupService.lookupCourse(
                                    semester: seed.semester, courseNo: seed.courseNo, language: lang
                                ), let match = results.first else { continue }
                                resolved.append((seed, match.CourseName, match.CourseTeacher, match.ClassRoomNo ?? seed.classroom))
                            }
                            let finalResolved = resolved
                            guard !finalResolved.isEmpty else { return }
                            await MainActor.run {
                                var current = DataCache.shared.loadUserAddedCourses()
                                var updated = false
                                for r in finalResolved {
                                    guard let idx = current.firstIndex(where: { $0.courseNo == r.seed.courseNo }) else { continue }
                                    current[idx] = SDCourse(
                                        courseNo: r.seed.courseNo,
                                        courseName: r.name,
                                        instructor: r.instructor,
                                        credits: r.seed.credits,
                                        classroom: r.classroom,
                                        enrolledCount: r.seed.enrolledCount,
                                        maxCount: r.seed.maxCount,
                                        schedule: r.seed.schedule,
                                        moodleIdNumber: r.seed.moodleIdNumber,
                                        semester: r.seed.semester,
                                        classroomMap: r.seed.classroomMap
                                    )
                                    updated = true
                                }
                                if updated {
                                    DataCache.shared.saveUserAddedCourses(current)
                                    NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
                                }
                            }
                        }
                    }
                }
            } else if Defaults[.syncCourses] {
                // Reached only when course sync is ON but the server has no
                // courses yet (first-time upload). When the toggle is OFF we
                // fall through and upload nothing — otherwise a disabled toggle
                // would still re-upload and resurrect cross-device deletions.
                let semester = CourseSelectionService.currentSemesterCode()
                let localCourses = DataCache.shared.loadCourses(semester: semester)
                if !localCourses.isEmpty {
                    uploadCourses(localCourses, semester: semester)
                    AppLogger.sync.info("[sync] backend empty, auto-uploaded \(localCourses.count, privacy: .public) local courses")
                }
            }

            // Update the revision watermark so the poller doesn't
            // immediately re-trigger after a full sync. When the reconcile was
            // skipped (edit raced the fetch), leave it stale so the next poll
            // re-pulls — the local op's drain can't be counted on to bump the
            // server revision (its PATCH may fail).
            if overrideEditGeneration == editGenerationAtFetch,
               let rev = json["current_revision"] as? Int {
                _lastKnownRevision = rev
            }

            UserDefaults.standard.set(Date(), forKey: "lastCourseSyncAt")
            NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
            ServerStatusTracker.shared.set(.ok, for: .backend)
            recordSyncSource(.backend)
        } catch {
            ServerStatusTracker.shared.set(.failed, for: .backend)
            recordSyncSource(.local)
            if case PushAPIError.httpStatus(401, _) = error, !retried {
                let reloginOk = await attemptBackendRelogin()
                if reloginOk {
                    AppLogger.sync.info("auto-relogin succeeded, retrying sync")
                    try? await Task.sleep(for: .milliseconds(500))
                    await syncOverridesFromBackend(retried: true)
                }
            }
            AppLogger.sync.error("syncOverrides failed: \(error, privacy: .public)")
        }
    }

    private func applyCourseOverrides(_ overrides: [[String: Any]], coursesArray: [[String: Any]]) {
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

        var customNames = DataCache.shared.loadCourseCustomNames()
        var colorCount = 0
        var nameCount = 0
        for o in overrides {
            guard let mId = o["moodle_id"] as? String ?? (o["moodle_id"] as? Int).map(String.init) else { continue }
            guard let courseNo = moodleIdToNo[mId] else { continue }
            if Defaults[.syncCourseColors], let colorHex = o["color_hex"] as? String, !colorHex.isEmpty {
                if let hex = UInt32(colorHex.dropFirst(), radix: 16) {
                    TigerDuckTheme.setColor(hex: hex, for: courseNo)
                    colorCount += 1
                    AppLogger.sync.debug("course color applied")
                }
            }
            if Defaults[.syncCourseNames], let serverNames = o["custom_names"] as? [String: String], !serverNames.isEmpty {
                var existing = customNames[courseNo] ?? [:]
                for (locale, name) in serverNames {
                    if name.isEmpty {
                        existing.removeValue(forKey: locale)
                    } else {
                        existing[locale] = name
                    }
                }
                customNames[courseNo] = existing.isEmpty ? nil : existing
                nameCount += 1
                AppLogger.sync.debug("course custom names updated")
            }
        }
        if nameCount > 0 {
            DataCache.shared.saveCourseCustomNames(customNames)
        }
    }

    func attemptBackendRelogin() async -> Bool {
        let atm = authTokenManager
        guard let studentId = authService.storedStudentId else { return false }
        let moodleToken = await MoodleTokenService.shared.currentToken()
        let moodlePrivateToken = KeychainManager.loadString(
            key: AppConstants.KeychainKeys.moodlePrivateToken
        )
        guard let moodleToken, !moodleToken.isEmpty else {
            AppLogger.sync.info("auto-relogin skipped: no Moodle token")
            return false
        }
        let platform = PushDeviceClass.platform(for: PushDeviceClass.resolvedForBuild)
        do {
            _ = try await atm.login(
                studentId: studentId,
                password: "",
                moodleToken: moodleToken,
                moodlePrivateToken: moodlePrivateToken,
                platform: platform
            )
            AppLogger.sync.info("auto-relogin: v3 JWT refreshed")
            pushCoordinator.refreshRegistrationAfterAuth()
            return true
        } catch {
            AppLogger.sync.error("auto-relogin failed: \(error, privacy: .public)")
            return false
        }
    }

    /// Fire-and-forget override sync to the backend. Local state is already
    /// updated by the ViewModel; this propagates to other devices.
    func syncAssignmentOverride(moodleId: String, status: String) {
        guard Defaults[.cloudSyncEnabled] else { return }
        AppLogger.sync.debug("override enqueue: \(moodleId, privacy: .private) → \(status, privacy: .public)")
        guard let moodleAssignmentId = Int(moodleId) else { return }
        overrideEditGeneration &+= 1
        // Bridge the gap until the op is durably in the outbox; from then
        // on pendingAssignmentOverrideIds() is the conflict-guard signal
        // until the PATCH actually lands on the server.
        pendingOverrides.insert(moodleId)
        Task { [weak self] in
            guard let self else { return }
            await cloudSyncCoordinator.enqueueAssignmentOverride(
                moodleCourseId: 0,
                moodleAssignmentId: moodleAssignmentId,
                localStatus: status)
            pendingOverrides.remove(moodleId)
        }
        cloudSyncCoordinator.scheduleTick(after: 1)
    }

    func syncCourseOverride(
        moodleCourseId: String,
        colorHex: String? = nil,
        customName: String? = nil,
        locale: String? = nil
    ) {
        guard Defaults[.cloudSyncEnabled] else { return }
        let semester = CourseSelectionService.currentSemesterCode()
        if let colorHex {
            cloudSyncCoordinator.enqueueCourseColorOverride(
                moodleId: moodleCourseId, semester: semester, colorHex: colorHex)
        }
        if let customName {
            cloudSyncCoordinator.enqueueCourseNameOverride(
                moodleId: moodleCourseId, semester: semester, customName: customName, locale: locale)
        }
        cloudSyncCoordinator.scheduleTick(after: 1)
    }

    func deleteBackendCourse(courseNo: String, semester: String) {
        guard Defaults[.cloudSyncEnabled] else { return }
        // Record the local delete so the sync reconcile's grace window doesn't
        // resurrect this course before the backend DELETE propagates (F).
        recentCourseDeletions[courseNo] = Date()
        // Enrolled (Moodle-linked) courses are keyed on the backend by
        // moodle_id; deleting them by the client key is a no-op server-side and
        // the course resurrects on the next sync. Prefer the moodle_id resolved
        // from the cached course; fall back to the client key for purely manual
        // courses that have no moodle_id.
        let moodleId = (DataCache.shared.loadCourses(semester: semester)
            + DataCache.shared.loadUserAddedCourses())
            .first { $0.courseNo == courseNo }?.moodleIdNumber
            .flatMap { $0.isEmpty ? nil : $0 }
        let courseKey = moodleId ?? "client:\(semester):\(courseNo)"
        let coordinator = pushCoordinator
        Task.detached {
            do {
                try await coordinator.deleteCourse(courseKey: courseKey)
                AppLogger.sync.info("deleteBackendCourse ok: \(courseKey, privacy: .public)")
            } catch {
                AppLogger.sync.error("deleteBackendCourse failed: \(error, privacy: .public)")
            }
        }
    }

    /// `semester` nil wipes every term; the class-table reset passes the
    /// term it is on so the others survive.
    func deleteBackendCourses(semester: String? = nil) async {
        guard Defaults[.cloudSyncEnabled] else { return }
        do {
            try await pushCoordinator.deleteAllCourses(semester: semester)
            AppLogger.sync.info("deleteBackendCourses ok: \(semester ?? "all", privacy: .public)")
        } catch {
            AppLogger.sync.error("deleteBackendCourses failed: \(error, privacy: .public)")
        }
    }

    func uploadCourses(_ courses: [SDCourse], semester: String, forceKeys: [String] = []) {
        guard Defaults[.cloudSyncEnabled] else { return }
        let request = courseUploadRequest(courses, semester: semester, forceKeys: forceKeys)
        let coordinator = pushCoordinator
        Task.detached {
            do {
                try await coordinator.uploadCourses(request)
                AppLogger.sync.info("uploadCourses: \(request.courses.count, privacy: .public) courses sent")
            } catch {
                AppLogger.sync.error("uploadCourses failed: \(error, privacy: .public)")
            }
        }
    }

    /// Same payload as ``uploadCourses`` but awaits the POST and rethrows.
    /// Use where the caller has to know whether the upload landed — notably
    /// the keep-local conflict resolution, which wipes the server first and so
    /// cannot treat a failed upload as fire-and-forget.
    func uploadCoursesAwaitingResult(
        _ courses: [SDCourse],
        semester: String,
        forceKeys: [String] = []
    ) async throws {
        guard Defaults[.cloudSyncEnabled] else { return }
        let request = courseUploadRequest(courses, semester: semester, forceKeys: forceKeys)
        try await pushCoordinator.uploadCourses(request)
        AppLogger.sync.info("uploadCourses: \(request.courses.count, privacy: .public) courses sent")
    }

    private func courseUploadRequest(
        _ courses: [SDCourse],
        semester: String,
        forceKeys: [String]
    ) -> PushAPI.CourseUploadRequest {
        let entries = courses.map { c in
            PushAPI.CourseUploadEntry(
                semester: semester,
                courseNo: c.courseNo,
                courseName: c.courseName,
                courseNameEn: nil,
                moodleId: c.moodleIdNumber,
                credits: c.credits > 0 ? Double(c.credits) : nil,
                classroom: c.classroom.isEmpty ? nil : c.classroom,
                instructors: c.instructor.isEmpty ? [] : [c.instructor],
                scheduleJson: c.schedule.isEmpty ? nil : Dictionary(uniqueKeysWithValues: c.schedule.map { ("\($0.key)", $0.value) }),
                classroomMap: c.classroomMap.isEmpty ? nil : c.classroomMap
            )
        }
        let colorMap = TigerDuckTheme.courseColorMap
        let overrides = courses.compactMap { c -> PushAPI.CourseOverrideUploadEntry? in
            guard let hex = colorMap[c.courseNo] else { return nil }
            // Key enrolled courses by moodle_id so the override round-trips: the
            // override endpoint resolves moodle_id, and applyCourseOverrides
            // maps server overrides back via moodle_id. A client-keyed override
            // for a moodle-linked course never maps back. Manual courses (no
            // moodle_id) keep the client key.
            let moodleId = c.moodleIdNumber.flatMap { $0.isEmpty ? nil : $0 }
            return PushAPI.CourseOverrideUploadEntry(
                courseKey: moodleId ?? "client:\(semester):\(c.courseNo)",
                colorHex: String(format: "#%06X", hex)
            )
        }
        return PushAPI.CourseUploadRequest(
            courses: entries, courseOverrides: overrides, forceKeys: forceKeys
        )
    }
}
