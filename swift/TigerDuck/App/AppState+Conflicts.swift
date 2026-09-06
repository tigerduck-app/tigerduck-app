// Conflict resolution for cloud sync — split out of AppState.swift.
//
// Two unrelated conflicts share this file because they share a shape: the
// server and the device both changed something while the device was away,
// and the user has to pick a winner.
//
//   * Assignment overrides (done/ignored) — `syncConflicts`.
//   * Re-enabled sync categories — `reenableConflict`, raised when a
//     category the user turned off has server state that predates the
//     switch-off, so silently pulling it would resurrect stale rows.
//
// Backing storage stays on the class in AppState.swift; only the decision
// logic lives here.

import SwiftUI
import SwiftData
import Defaults
import os

extension AppState {

    /// Body of the sync-conflict alert, shared by HomeView and MacHomeView.
    var syncConflictAlertMessage: String {
        let lines = syncConflicts.map { item in
            "• " + String(format: String(localized: "sync_conflict_item_header"), item.kind, item.label)
                + "\n  " + String(format: String(localized: "sync_conflict_item_detail"), item.localLabel, item.serverLabel)
        }
        return ([String(localized: "sync_conflict_message")] + lines).joined(separator: "\n")
    }

    func resolveSyncConflicts(keepLocal: Bool) {
        if keepLocal {
            for c in syncConflicts {
                syncAssignmentOverride(moodleId: c.id, status: c.localStatus)
            }
        } else {
            let serverArchived = pendingSyncServerArchived
            let serverCompleted = pendingSyncServerCompleted
            Task { [weak self] in
                guard let self else { return }
                // Same guard as the pull path: edits queued in the outbox are
                // in flight to the server and must survive "keep server".
                let inFlight = await cloudSyncCoordinator.pendingAssignmentOverrideIds()
                let protectedOverrides = pendingOverrides.union(inFlight)
                let safeArchived = serverArchived.union(
                    DataCache.shared.loadArchivedAssignmentIds().filter { protectedOverrides.contains($0) }
                )
                let safeCompleted = serverCompleted.union(
                    DataCache.shared.loadLocallyCompletedAssignmentIds().filter { protectedOverrides.contains($0) }
                )
                DataCache.shared.replaceArchivedAssignmentIds(safeArchived)
                DataCache.shared.replaceLocallyCompletedAssignmentIds(safeCompleted)
                NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
            }
        }
        syncConflicts = []
        pendingSyncServerArchived = []
        pendingSyncServerCompleted = []
    }

    struct ReenableConflict {
        let categories: [String]
        let description: String
    }

    func markCategoryReenabled(_ category: String) {
        Defaults[.pendingConflictCategories].insert(category)
        AppLogger.sync.info("[reenable] marked category: \(category, privacy: .public), pending=\(Defaults[.pendingConflictCategories].sorted(), privacy: .public)")
    }

    func checkPendingConflicts(retriesLeft: Int = 2) {
        checkPendingConflicts(retriesLeft: retriesLeft, isRetry: false)
    }

    /// - Parameter isRetry: `true` only for the controlled re-entry from our
    ///   own 401 handler, which reuses the in-flight flag the outer call holds.
    func checkPendingConflicts(retriesLeft: Int, isRetry: Bool) {
        let pending = Defaults[.pendingConflictCategories]
        guard !pending.isEmpty, Defaults[.cloudSyncEnabled] else {
            AppLogger.sync.info("[reenable] checkPendingConflicts skip: pending=\(Defaults[.pendingConflictCategories].sorted(), privacy: .public) syncEnabled=\(Defaults[.cloudSyncEnabled], privacy: .public)")
            return
        }
        // Serialize the check. It is a network round-trip whose verdict is only
        // valid for the `pending` snapshot it started with, and it is driven by
        // `onAppear`, `onDisappear` and every sync-category toggle — so two can
        // easily overlap. The slower one then lands after the user has already
        // resolved the faster one's dialog and re-presents it from a stale
        // snapshot; dismissing that dialog re-runs the keep-local upload
        // against categories the user never agreed to.
        //
        // Callers are views, so this guard-and-set pair runs on the main actor
        // and cannot interleave; the flag is cleared back on the main actor.
        if !isRetry {
            guard !isCheckingConflicts else {
                AppLogger.sync.info("[reenable] checkPendingConflicts skipped — already in flight")
                return
            }
            isCheckingConflicts = true
        }
        AppLogger.sync.info("[reenable] checkPendingConflicts start: pending=\(pending.sorted(), privacy: .public)")
        Task {
            // Set when we hand the flag to a 401 retry, which owns it from
            // there. The retry runs in its own Task, so releasing the flag here
            // would let an unrelated caller start while it is still in flight.
            var handedOffToRetry = false
            defer {
                if !isRetry && !handedOffToRetry {
                    Task { @MainActor in
                        self.isCheckingConflicts = false
                        // A category marked while this check was in flight was
                        // turned away by the guard above. Pick it up now rather
                        // than stranding it until the user next enters or
                        // leaves Settings. This terminates: the re-run snapshots
                        // the grown set, so its own completion sees no growth.
                        let current = Defaults[.pendingConflictCategories]
                        if self.reenableConflict == nil, !current.subtracting(pending).isEmpty {
                            self.checkPendingConflicts()
                        }
                    }
                }
            }
            do {
                let json = try await pushCoordinator.fetchFullSync()
                var diffs: [String] = []

                let coursesArray = json["courses"] as? [[String: Any]] ?? []

                if pending.contains("courses") {
                    // Compare term by term, including user-added courses (they
                    // are uploaded, so the server lists them). A term one side
                    // has never seen is not a conflict — the reconcile uploads
                    // or merges it — so only terms both sides know count.
                    let deletedNos = Set(DataCache.shared.loadDeletedCourseNos())
                    let serverSemesters = coursesArray.compactMap { $0["semester"] as? String }.filter { !$0.isEmpty }
                    var localOnly = 0
                    var serverOnly = 0
                    for semester in Set(serverSemesters).union(SemesterCatalog.availableSemesters()) {
                        let serverNos = Set(coursesArray
                            .filter { ($0["semester"] as? String) == semester && Self.isFiled($0, under: semester) }
                            .compactMap { $0["course_no"] as? String })
                        let localNos = Set(DataCache.shared.loadCourses(semester: semester).map(\.courseNo))
                            .union(DataCache.shared.loadUserAddedCourses(semester: semester).map(\.courseNo))
                            .filter { !CourseTombstone.isHidden($0, semester: semester, in: deletedNos) }
                        guard !serverNos.isEmpty, !localNos.isEmpty else { continue }
                        localOnly += localNos.subtracting(serverNos).count
                        serverOnly += serverNos.subtracting(localNos).count
                        AppLogger.sync.info("[reenable] courses \(semester, privacy: .public): local=\(localNos.sorted(), privacy: .public) server=\(serverNos.sorted(), privacy: .public)")
                    }
                    if localOnly > 0 && serverOnly > 0 {
                        diffs.append(String(localized: "sync_conflict_reenable_courses \(localOnly) \(serverOnly)"))
                    } else if localOnly > 0 {
                        diffs.append(String(localized: "sync_conflict_reenable_courses_local_only \(localOnly)"))
                    } else if serverOnly > 0 {
                        diffs.append(String(localized: "sync_conflict_reenable_courses_server_only \(serverOnly)"))
                    } else {
                        AppLogger.sync.info("[reenable] courses MATCH — no conflict")
                    }
                }

                if pending.contains("course_colors") || pending.contains("course_names") {
                    let overrides = json["course_overrides"] as? [[String: Any]] ?? []
                    var moodleIdToNo: [String: String] = [:]
                    for c in coursesArray {
                        guard let mId = c["moodle_id"] as? String ?? (c["moodle_id"] as? Int).map(String.init) else { continue }
                        if let courseNo = c["course_no"] as? String, !courseNo.isEmpty {
                            moodleIdToNo[mId] = courseNo
                        }
                    }
                    AppLogger.sync.info("[reenable] overrides=\(overrides.count, privacy: .public) moodleIdMap=\(moodleIdToNo.count, privacy: .public)")

                    if pending.contains("course_colors") {
                        let localColorMap = TigerDuckTheme.courseColorMap
                        var colorMismatches: [String] = []
                        for o in overrides {
                            guard let mId = o["moodle_id"] as? String ?? (o["moodle_id"] as? Int).map(String.init),
                                  let courseNo = moodleIdToNo[mId],
                                  let serverHex = o["color_hex"] as? String, !serverHex.isEmpty else { continue }
                            let localHex = localColorMap[courseNo].map { String(format: "#%06X", $0) }
                            if localHex != serverHex {
                                colorMismatches.append("\(courseNo): local=\(localHex ?? "nil") server=\(serverHex)")
                            }
                        }
                        AppLogger.sync.info("[reenable] colors: \(colorMismatches.isEmpty ? "MATCH" : "DIFFER (\(colorMismatches.count))", privacy: .public)")
                        if !colorMismatches.isEmpty {
                            for m in colorMismatches.prefix(5) { AppLogger.sync.debug("[reenable]   \(m, privacy: .public)") }
                            diffs.append(String(localized: "sync_conflict_reenable_colors_differ"))
                        }
                    }

                    if pending.contains("course_names") {
                        let localNames = DataCache.shared.loadCourseCustomNames()
                        var nameMismatches: [String] = []
                        var serverNosWithNames = Set<String>()
                        for o in overrides {
                            guard let mId = o["moodle_id"] as? String ?? (o["moodle_id"] as? Int).map(String.init),
                                  let courseNo = moodleIdToNo[mId],
                                  let serverNames = o["custom_names"] as? [String: String], !serverNames.isEmpty else { continue }
                            serverNosWithNames.insert(courseNo)
                            if (localNames[courseNo] ?? [:]) != serverNames {
                                nameMismatches.append("\(courseNo): local=\(localNames[courseNo] ?? [:]) server=\(serverNames)")
                            }
                        }
                        for (courseNo, locales) in localNames where !locales.isEmpty && !serverNosWithNames.contains(courseNo) {
                            nameMismatches.append("\(courseNo): local=\(locales) server=default")
                        }
                        AppLogger.sync.info("[reenable] names: \(nameMismatches.isEmpty ? "MATCH" : "DIFFER (\(nameMismatches.count))", privacy: .public)")
                        if !nameMismatches.isEmpty {
                            for m in nameMismatches.prefix(5) { AppLogger.sync.debug("[reenable]   \(m, privacy: .public)") }
                            diffs.append(String(localized: "sync_conflict_reenable_names_differ"))
                        }
                    }
                }

                if pending.contains("assignments") {
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
                    let localArchivedIds = DataCache.shared.loadArchivedAssignmentIds()
                    let localCompletedIds = DataCache.shared.loadLocallyCompletedAssignmentIds()
                    let archivedMatch = localArchivedIds == serverArchivedIds
                    let completedMatch = localCompletedIds == serverCompletedIds
                    AppLogger.sync.info("[reenable] assignments: localArchived=\(localArchivedIds.count, privacy: .public) serverArchived=\(serverArchivedIds.count, privacy: .public) match=\(archivedMatch, privacy: .public) | localCompleted=\(localCompletedIds.count, privacy: .public) serverCompleted=\(serverCompletedIds.count, privacy: .public) match=\(completedMatch, privacy: .public)")
                    if !archivedMatch || !completedMatch {
                        diffs.append(String(localized: "sync_conflict_reenable_assignments_differ"))
                    }
                }

                AppLogger.sync.info("[reenable] result: \(diffs.count, privacy: .public) diffs → \(diffs.isEmpty ? "no conflict" : "SHOW POPUP", privacy: .public)")
                await MainActor.run {
                    // Only report on categories that are still pending. A
                    // resolve that landed while this check was in flight
                    // already cleared its own categories and changed the
                    // server state the diffs above were computed from —
                    // re-presenting them would show the user a dialog they
                    // just dismissed, and dismissing it again would re-run
                    // the keep-local upload.
                    let stillPending = Defaults[.pendingConflictCategories]
                    let checked = pending.intersection(stillPending)
                    guard !checked.isEmpty else {
                        AppLogger.sync.info("[reenable] result discarded — resolved while in flight")
                        return
                    }
                    if !diffs.isEmpty {
                        reenableConflict = ReenableConflict(
                            categories: Array(checked),
                            description: diffs.joined(separator: "\n")
                        )
                    } else {
                        Defaults[.pendingConflictCategories].subtract(checked)
                    }
                }
            } catch {
                AppLogger.sync.error("[reenable] checkPendingConflicts FAILED: \(error, privacy: .public) — pending kept for retry")
                if case PushAPIError.httpStatus(401, _) = error, retriesLeft > 0 {
                    let reloginOk = await attemptBackendRelogin()
                    if reloginOk {
                        AppLogger.sync.info("[reenable] relogin succeeded, retrying conflict check")
                        try? await Task.sleep(for: .milliseconds(500))
                        handedOffToRetry = !isRetry
                        await MainActor.run {
                            self.checkPendingConflicts(retriesLeft: retriesLeft - 1, isRetry: true)
                        }
                    }
                }
            }
        }
    }

    func resolveReenableConflict(keepLocal: Bool) {
        guard let conflict = reenableConflict else { return }
        AppLogger.sync.info("[reenable] resolve: keepLocal=\(keepLocal, privacy: .public) categories=\(conflict.categories, privacy: .public)")
        reenableConflict = nil
        // Subtract rather than clear. A category re-enabled after this check
        // started was never part of this dialog, so clearing it would record a
        // decision the user was never asked to make; leaving it pending lets
        // the next check present it on its own.
        Defaults[.pendingConflictCategories].subtract(conflict.categories)
        let coordinator = pushCoordinator
        Task {
            if keepLocal {
                if conflict.categories.contains("courses") {
                    // Every term goes up, and each includes its user-added
                    // courses (stored separately from the portal cache).
                    // Uploading only the portal cache drops them from the
                    // backend, and the next reconcile then deletes them
                    // locally too — permanent loss on the path meant to
                    // preserve local state. forceKeys re-asserts them past
                    // any tombstone.
                    // Wipe the server list first, THEN upload. uploadCourses
                    // upserts (never replaces), so if the delete fails we must
                    // not upload — that would layer local courses onto the stale
                    // server state and resurrect the very courses the user
                    // deleted locally, contradicting "keep local".
                    //
                    // Await the upload instead of firing it detached. Between
                    // the delete and the upload the server holds no courses at
                    // all, so a silently-dropped upload leaves "keep local"
                    // having wiped the user's cloud copy — the exact opposite
                    // of what they chose. Other devices do not mass-delete off
                    // an empty server (the reconcile in `syncOverridesFromBackend`
                    // is gated on `!coursesArray.isEmpty`, and the branch below
                    // it re-uploads instead), but this device's user-added
                    // courses are not covered by that auto-upload and would
                    // stay missing. On failure put the category back so the
                    // next check re-detects the divergence and re-prompts.
                    do {
                        try await coordinator.deleteAllCourses()
                        for semester in SemesterCatalog.availableSemesters() {
                            let userAdded = DataCache.shared.loadUserAddedCourses(semester: semester)
                            let courses = DataCache.shared.loadCourses(semester: semester) + userAdded
                            guard !courses.isEmpty else { continue }
                            try await uploadCoursesAwaitingResult(
                                courses, semester: semester,
                                forceKeys: userAdded.map { "client:\(semester):\($0.courseNo)" }
                            )
                        }
                    } catch {
                        AppLogger.sync.error("[reenable] keep-local course sync failed (server may be empty): \(error, privacy: .public)")
                        await MainActor.run { markCategoryReenabled("courses") }
                    }
                }
                if conflict.categories.contains("course_colors") || conflict.categories.contains("course_names") {
                    // The color/name maps are keyed by courseNo, but the
                    // override endpoint resolves moodle_id — map through the
                    // cached course list (and skip courses without one, same
                    // as the live edit paths).
                    let moodleIdByCourseNo = Dictionary(
                        SemesterCatalog.availableSemesters()
                            .flatMap { DataCache.shared.loadCourses(semester: $0) }
                            .compactMap { c in c.moodleIdNumber.map { (c.courseNo, $0) } },
                        uniquingKeysWith: { first, _ in first })
                    if conflict.categories.contains("course_colors") {
                        let colorMap = TigerDuckTheme.courseColorMap
                        for (courseNo, hex) in colorMap {
                            guard let moodleId = moodleIdByCourseNo[courseNo] else { continue }
                            syncCourseOverride(moodleCourseId: moodleId, colorHex: String(format: "#%06X", hex))
                        }
                    }
                    if conflict.categories.contains("course_names") {
                        let customNames = DataCache.shared.loadCourseCustomNames()
                        for (courseNo, locales) in customNames {
                            guard let moodleId = moodleIdByCourseNo[courseNo] else { continue }
                            for (locale, name) in locales where !name.isEmpty {
                                syncCourseOverride(moodleCourseId: moodleId, customName: name, locale: locale)
                            }
                        }
                    }
                }
                if conflict.categories.contains("assignments") {
                    for id in DataCache.shared.loadArchivedAssignmentIds() {
                        syncAssignmentOverride(moodleId: id, status: "archived")
                    }
                    for id in DataCache.shared.loadLocallyCompletedAssignmentIds() {
                        syncAssignmentOverride(moodleId: id, status: "locally_completed")
                    }
                }
            } else {
                if conflict.categories.contains("courses") {
                    DataCache.shared.saveDeletedCourseNos([])
                }
                if conflict.categories.contains("course_colors") {
                    DataCache.shared.saveCourseColorMap([:])
                    TigerDuckTheme.reload()
                }
                if conflict.categories.contains("course_names") {
                    DataCache.shared.saveCourseCustomNames([:])
                }
                if conflict.categories.contains("assignments") {
                    DataCache.shared.replaceArchivedAssignmentIds([])
                    DataCache.shared.replaceLocallyCompletedAssignmentIds([])
                }
                await syncOverridesFromBackend()
            }
        }
    }
}
