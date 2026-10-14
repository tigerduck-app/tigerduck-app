// Sync conflicts: the server and this device both changed something while the device was away,
// and the user picks a winner. Assignment overrides use `syncConflicts`; re-enabled sync
// categories use `reenableConflict`, since silently pulling them would resurrect stale rows.

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
                let safeArchived = Self.mergedMarks(
                    server: serverArchived,
                    local: DataCache.shared.loadArchivedAssignmentIds(),
                    protected: protectedOverrides
                )
                let safeCompleted = Self.mergedMarks(
                    server: serverCompleted,
                    local: DataCache.shared.loadLocallyCompletedAssignmentIds(),
                    protected: protectedOverrides
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
        /// What the check found, for Keep Local to clear the ones this device does not ignore, or
        /// nil when it compared no course settings: the resolution then leaves them alone too.
        var serverIgnoredCourses: [ServerIgnoredCourse]?
        /// The assignments the check found marked on the server, for Keep Local to clear the ones
        /// this device has no mark on.
        let serverMarkedAssignments: Set<String>
    }

    func markCategoryReenabled(_ category: String) {
        // The server may have dropped the lists while the category was off on every device.
        pushCoordinator.forgetUploads()
        Self.markForReenableCheck(category, signedIn: authService.hasStoredCredentials)
    }

    /// Marks `category` for the re-enable check, which compares this device's copy of the account's
    /// data with the server's. Before this device has taken the category's data, as after a sign-in
    /// or with its switch off in every sync since, it has no copy to compare, and Use Local would
    /// send this device's own over the server's: the category is left to the first sync that takes
    /// it, which takes the server's data. Signed out, the check has no session, and the mark would
    /// wait for whoever signs in next.
    static func markForReenableCheck(_ category: String, signedIn: Bool) {
        let synced = hasSynced(category)
        guard signedIn, synced else {
            AppLogger.sync.info("[reenable] not marked: \(category, privacy: .public), signedIn=\(signedIn, privacy: .public) synced=\(synced, privacy: .public)")
            return
        }
        Defaults[.pendingConflictCategories].insert(category)
        AppLogger.sync.info("[reenable] marked category: \(category, privacy: .public), pending=\(Defaults[.pendingConflictCategories].sorted(), privacy: .public)")
    }

    /// Whether this device holds the signed-in account's data of `category`: each full sync records
    /// the categories it took (`recordFullSync`), as does the update for an account signed in then,
    /// and sign-out clears them (`forgetSyncProgress`). `assignmentMarksSyncedOnce` stays apart: the
    /// update leaves it false, so that the first sync still uploads marks the server lacks.
    static func hasSynced(_ category: String) -> Bool {
        Defaults[.categoriesSyncedOnce].contains(category)
    }

    static let reenableCategories: Set<String> = ["courses", "course_colors", "course_names", "assignments"]

    /// The re-enable check's categories whose sync switch is on.
    static func switchedOnCategories() -> Set<String> {
        var categories: Set<String> = []
        if Defaults[.syncCourses] { categories.insert("courses") }
        if Defaults[.syncCourseColors] { categories.insert("course_colors") }
        if Defaults[.syncCourseNames] { categories.insert("course_names") }
        if Defaults[.syncAssignments] { categories.insert("assignments") }
        return categories
    }

    func checkPendingConflicts(retriesLeft: Int = 2) {
        checkPendingConflicts(retriesLeft: retriesLeft, isRetry: false)
    }

    /// - Parameter isRetry: `true` only for the controlled re-entry from our
    ///   own 401 handler, which takes over the in-flight flag the outer call holds
    ///   and releases it when it ends, as the outer call would have.
    func checkPendingConflicts(retriesLeft: Int, isRetry: Bool) {
        let pending = Defaults[.pendingConflictCategories]
        let generation = authService.loginGeneration
        guard !pending.isEmpty, Defaults[.cloudSyncEnabled] else {
            AppLogger.sync.info("[reenable] checkPendingConflicts skip: pending=\(Defaults[.pendingConflictCategories].sorted(), privacy: .public) syncEnabled=\(Defaults[.cloudSyncEnabled], privacy: .public)")
            if isRetry { endConflictCheck(checked: pending, startedIn: generation) }
            return
        }
        // One check at a time: a verdict is valid only for its `pending` snapshot, and a slower
        // second check re-presents a dialog the user has answered.
        // Callers are views: guard, set and clear run on the main actor and cannot interleave.
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
                if !handedOffToRetry {
                    Task { @MainActor in self.endConflictCheck(checked: pending, startedIn: generation) }
                }
            }
            do {
                let json = try await pushCoordinator.fetchFullSync()
                conflictCheckOwed = false
                var diffs: [String] = []
                var serverMarkedAssignments = Set<String>()

                let coursesArray = json["courses"] as? [[String: Any]] ?? []
                let serverIgnoredCourses = Self.serverIgnoredCourses(
                    json["course_overrides"] as? [[String: Any]] ?? [], syncsCourses: Defaults[.syncCourses]
                )

                if pending.contains("courses") {
                    // Compare term by term, user-added courses included (they are uploaded,
                    // so the server lists them). Only terms both sides know count: the
                    // reconcile uploads or merges a term only one side has seen.
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
                        AppLogger.sync.info("[reenable] courses \(semester, privacy: .public): local=\(localNos.sorted(), privacy: .private) server=\(serverNos.sorted(), privacy: .private)")
                    }
                    if localOnly > 0 && serverOnly > 0 {
                        diffs.append(String(format: String(localized: "sync_conflict_reenable_courses"), String(localOnly), String(serverOnly)))
                    } else if localOnly > 0 {
                        diffs.append(String(format: String(localized: "sync_conflict_reenable_courses_local_only"), String(localOnly)))
                    } else if serverOnly > 0 {
                        diffs.append(String(format: String(localized: "sync_conflict_reenable_courses_server_only"), String(serverOnly)))
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
                            for m in colorMismatches.prefix(5) { AppLogger.sync.debug("[reenable]   \(m, privacy: .private)") }
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
                            for m in nameMismatches.prefix(5) { AppLogger.sync.debug("[reenable]   \(m, privacy: .private)") }
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
                    serverMarkedAssignments = serverArchivedIds.union(serverCompletedIds)
                    let localArchivedIds = DataCache.shared.loadArchivedAssignmentIds()
                    let localCompletedIds = DataCache.shared.loadLocallyCompletedAssignmentIds()
                    let archivedMatch = localArchivedIds == serverArchivedIds
                    let completedMatch = localCompletedIds == serverCompletedIds
                    let coursesDiffer = Self.ignoredCoursesDiffer(
                        server: serverIgnoredCourses.map { Set($0.map(\.key)) },
                        decided: Self.serverDecidedCourses(json["course_overrides"] as? [[String: Any]] ?? [])
                            .union(Self.recreatedCourses(
                                listed: Self.listedCourseRows(coursesArray), seen: Defaults[.courseRowIdsSeen]
                            )),
                        listed: Self.listedCourses(coursesArray),
                        local: DataCache.shared.loadIgnoredAssignmentCourses(),
                        snapshotSemesters: Set(coursesArray.compactMap { $0["semester"] as? String })
                    )
                    AppLogger.sync.info("[reenable] assignments: localArchived=\(localArchivedIds.count, privacy: .public) serverArchived=\(serverArchivedIds.count, privacy: .public) match=\(archivedMatch, privacy: .public) | localCompleted=\(localCompletedIds.count, privacy: .public) serverCompleted=\(serverCompletedIds.count, privacy: .public) match=\(completedMatch, privacy: .public) | ignoredCoursesDiffer=\(coursesDiffer, privacy: .public)")
                    if !archivedMatch || !completedMatch || coursesDiffer {
                        diffs.append(String(localized: "sync_conflict_reenable_assignments_differ"))
                    }
                }

                AppLogger.sync.info("[reenable] result: \(diffs.count, privacy: .public) diffs → \(diffs.isEmpty ? "no conflict" : "SHOW POPUP", privacy: .public)")
                await MainActor.run {
                    // After a sign-out the diffs compare the previous account's server state
                    // with cleared caches, and with sync off there is nothing to reconcile.
                    guard fullSyncMayWrite(since: generation) else {
                        AppLogger.sync.info("[reenable] result discarded — signed out or sync off while in flight")
                        return
                    }
                    // Report only categories still pending: a resolve that landed mid-check
                    // cleared its own and changed the server state behind these diffs. Showing
                    // them again repeats a dialog the user has answered.
                    let stillPending = Defaults[.pendingConflictCategories]
                    let checked = pending.intersection(stillPending)
                    guard !checked.isEmpty else {
                        AppLogger.sync.info("[reenable] result discarded — resolved while in flight")
                        return
                    }
                    if !diffs.isEmpty {
                        reenableConflict = ReenableConflict(
                            categories: Array(checked),
                            description: diffs.joined(separator: "\n"),
                            serverIgnoredCourses: serverIgnoredCourses,
                            serverMarkedAssignments: serverMarkedAssignments
                        )
                    } else {
                        Defaults[.pendingConflictCategories].subtract(checked)
                        // The edits the check held can go now rather than at the next tick.
                        cloudSyncCoordinator.scheduleTick()
                    }
                }
            } catch {
                conflictCheckOwed = true
                AppLogger.sync.error("[reenable] checkPendingConflicts FAILED: \(error, privacy: .private) — pending kept for retry")
                if case PushAPIError.httpStatus(401, _) = error, retriesLeft > 0 {
                    let reloginOk = await attemptBackendRelogin()
                    if reloginOk {
                        AppLogger.sync.info("[reenable] relogin succeeded, retrying conflict check")
                        try? await Task.sleep(for: .milliseconds(500))
                        handedOffToRetry = true
                        await MainActor.run {
                            self.checkPendingConflicts(retriesLeft: retriesLeft - 1, isRetry: true)
                        }
                    }
                }
            }
        }
    }

    private func endConflictCheck(checked pending: Set<String>, startedIn generation: Int) {
        isCheckingConflicts = false
        // Re-run now rather than strand a category the guard turned away until the next Settings
        // visit. This terminates: the re-run snapshots the current set and sign-in, so unless one
        // changes again its completion finds nothing left.
        let unchecked = Self.categoriesLeftToCheck(
            pending: Defaults[.pendingConflictCategories], checked: pending,
            signedOutSince: generation != authService.loginGeneration
        )
        if reenableConflict == nil, !unchecked.isEmpty {
            checkPendingConflicts()
        }
    }

    /// Runs the pending re-enable check once a full sync or a revision poll has reached the server,
    /// if it is owed one. Until a check runs, the outbox holds the edits of its categories.
    func retryOwedConflictCheck() {
        guard Self.conflictCheckIsOwed(
            owed: conflictCheckOwed, pending: Defaults[.pendingConflictCategories],
            checking: isCheckingConflicts, awaitingAnswer: reenableConflict != nil
        ) else { return }
        checkPendingConflicts()
    }

    /// Whether the pending categories are owed a check: none has reached the server since this
    /// launch or since the last one failed, none is running, and no verdict waits for the user.
    nonisolated static func conflictCheckIsOwed(
        owed: Bool, pending: Set<String>, checking: Bool, awaitingAnswer: Bool
    ) -> Bool {
        owed && !pending.isEmpty && !checking && !awaitingAnswer
    }

    /// The categories a finished re-enable check leaves to another: those marked while it ran, which
    /// the one-at-a-time guard turned away, or after a sign-out every pending one, as the check drops
    /// its result then and so settled none.
    nonisolated static func categoriesLeftToCheck(
        pending: Set<String>, checked: Set<String>, signedOutSince: Bool
    ) -> Set<String> {
        signedOutSince ? pending : pending.subtracting(checked)
    }

    /// `isPresented` of the re-enable alert. Only its buttons answer it, and SwiftUI closes the alert
    /// after their action runs. Closed any other way, it answers nothing: nothing is sent, and the
    /// categories stay pending for the next check to ask about again.
    static func reenableAlertIsPresented(_ conflict: Binding<ReenableConflict?>) -> Binding<Bool> {
        Binding(
            get: { conflict.wrappedValue != nil },
            set: { isPresented in
                guard !isPresented, conflict.wrappedValue != nil else { return }
                AppLogger.sync.info("[reenable] alert closed unanswered, categories left pending")
                conflict.wrappedValue = nil
            }
        )
    }

    /// Applies the user's answer to `reenableConflict`. Keeping local courses awaits every
    /// request and asks again on any failure: until a term's upload lands, the server holds
    /// none of its courses and the reset's tombstones hide them on every other device.
    func resolveReenableConflict(keepLocal: Bool) {
        guard let conflict = reenableConflict else { return }
        AppLogger.sync.info("[reenable] resolve: keepLocal=\(keepLocal, privacy: .public) categories=\(conflict.categories, privacy: .public)")
        reenableConflict = nil
        let coordinator = pushCoordinator
        // Keep Local stops at a sign-out: its course requests would go out on the next account's
        // session, the check it asks again for would be left to that account, and the rest would
        // read emptied caches.
        let generation = authService.loginGeneration
        let isCurrent = { [weak self] in self?.authService.loginGeneration == generation }
        Task {
            if !keepLocal, conflict.categories.contains("assignments") {
                // Before the subtract below: until then the pending check holds these in the
                // outbox, and once it ends a drain could send them before they are dropped.
                await cloudSyncCoordinator.discardAssignmentOverrides()
                if conflict.serverIgnoredCourses != nil {
                    await cloudSyncCoordinator.discardCourseIgnores()
                }
            }
            // Subtract, not clear: a category re-enabled after this check started was not in this
            // dialog, so clearing it would record a decision the user was never asked to make.
            // Left pending, the next check presents it on its own.
            Defaults[.pendingConflictCategories].subtract(conflict.categories)
            if keepLocal {
                if conflict.categories.contains("courses"), CourseUploadPolicy.uploadsCourses {
                    let terms = SemesterCatalog.availableSemesters().map { semester in
                        (semester: semester,
                         courses: DataCache.shared.loadCourses(semester: semester)
                            + DataCache.shared.loadUserAddedCourses(semester: semester))
                    }
                    // Latched and stamped as in `deleteBackendCourses`: a sync that read a term
                    // mid-way would un-hide the courses the upload puts back before their deletes.
                    let latched = Set(terms.map(\.semester))
                    resettingSemesters.formUnion(latched)
                    defer {
                        resettingSemesters.subtract(latched)
                        for semester in latched { DataCache.shared.recordSemesterReset(semester) }
                    }
                    do {
                        try await Self.keepLocalCourses(
                            terms, hiding: Set(DataCache.shared.loadDeletedCourseNos()), on: coordinator,
                            isCurrent: isCurrent
                        )
                    } catch {
                        AppLogger.sync.error("[reenable] keep-local course sync failed (server may be empty): \(error, privacy: .private)")
                        await MainActor.run { if isCurrent() { markCategoryReenabled("courses") } }
                    }
                }
                guard isCurrent() else { return }
                if conflict.categories.contains("course_colors") || conflict.categories.contains("course_names") {
                    // The colour and name maps are keyed by courseNo, but the override endpoint
                    // resolves moodle_id: map through the cached course list and skip courses
                    // without one, as the live edit paths do.
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
                    let archived = DataCache.shared.loadArchivedAssignmentIds()
                    let completed = DataCache.shared.loadLocallyCompletedAssignmentIds()
                    for id in archived {
                        syncAssignmentOverride(moodleId: id, status: "archived")
                    }
                    for id in completed {
                        syncAssignmentOverride(moodleId: id, status: "locally_completed")
                    }
                    let cleared = Self.assignmentMarksToClear(
                        server: conflict.serverMarkedAssignments, local: archived.union(completed)
                    )
                    for id in cleared {
                        syncAssignmentOverride(moodleId: id, status: "none")
                    }
                    if let serverIgnoredCourses = conflict.serverIgnoredCourses {
                        let ignoredCourses = DataCache.shared.loadIgnoredAssignmentCourses()
                        syncCourseIgnores(ignoredCourses)
                        for course in Self.courseIgnoresToClear(server: serverIgnoredCourses, local: ignoredCourses) {
                            syncCourseIgnore(
                                semester: course.semester, courseNo: course.courseNo,
                                moodleIdNumber: course.moodleId, ignore: false
                            )
                        }
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
                    if conflict.serverIgnoredCourses != nil {
                        DataCache.shared.replaceIgnoredAssignmentCourses([])
                    }
                }
                await syncOverridesFromBackend()
            }
        }
    }

    /// "Use Local" for courses, term by term: reset a term this device caches courses for, upload
    /// them, then delete every course hidden here; one missing from the cache, which is per language,
    /// goes up as a stub first so its delete has a row to remove. The reset makes every tombstone in
    /// the term this device's, which the upload releases. The deletes leave single-course tombstones,
    /// which bind this device too, so the roster its next refresh uploads cannot bring a hidden course
    /// back. Not a full reset: that erases every term's tombstones and sets `courses_reset_at`, which
    /// tells every device, this one included, to drop its hidden and manual courses.
    /// Once `isCurrent` turns false, as at a sign-out, it sends nothing more and throws `CancellationError`.
    static func keepLocalCourses(
        _ terms: [(semester: String, courses: [SDCourse])],
        hiding deletedNos: Set<String>,
        on backend: some CourseSyncBackend,
        isCurrent: () -> Bool = { true }
    ) async throws {
        for (semester, courses) in terms {
            let hiddenNos = CourseTombstone.courseNos(hiddenIn: semester, in: deletedNos)
            let stubs = hiddenNos.subtracting(courses.map(\.courseNo)).sorted()
                .map { SDCourse(courseNo: $0, courseName: $0) }
            guard !courses.isEmpty || !stubs.isEmpty else { continue }
            if !courses.isEmpty {
                guard isCurrent() else { throw CancellationError() }
                try await backend.deleteAllCourses(semester: semester)
            }
            guard isCurrent() else { throw CancellationError() }
            try await backend.uploadCourses(courseUploadRequest(courses + stubs, semester: semester, forceKeys: []))
            for courseNo in hiddenNos.sorted() {
                guard isCurrent() else { throw CancellationError() }
                try await backend.deleteCourse(courseKey: "client:\(semester):\(courseNo)")
            }
        }
    }
}

/// The course requests "Use Local" sends, so a test can stand in for the backend.
protocol CourseSyncBackend {
    func deleteAllCourses(semester: String?) async throws
    func uploadCourses(_ request: PushAPI.CourseUploadRequest) async throws
    func deleteCourse(courseKey: String) async throws
}

extension PushCoordinator: CourseSyncBackend {}
