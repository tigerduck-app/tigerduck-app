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

    /// `isPresented` of the alert for assignments marked differently here and on the server. Only
    /// its buttons answer it, as with `reenableAlertIsPresented`. Closed any other way, it sends
    /// nothing and leaves the marks as they are here, and the next full sync asks again.
    static func syncConflictAlertIsPresented(_ conflicts: Binding<[SyncConflictItem]>) -> Binding<Bool> {
        Binding(
            get: { !conflicts.wrappedValue.isEmpty },
            set: { isPresented in
                guard !isPresented, !conflicts.wrappedValue.isEmpty else { return }
                AppLogger.sync.info("[syncConflicts] alert closed unanswered, marks left as they are")
                conflicts.wrappedValue = []
            }
        )
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
        useLocalHold.noteReenabled(category)
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
        let pending = Self.categoriesToCheck(
            pending: Defaults[.pendingConflictCategories], answering: useLocalHold.held
        )
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
                    let outcome = Self.conflictCheckOutcome(
                        mayWrite: fullSyncMayWrite(since: generation), checked: pending,
                        stillPending: Self.categoriesToCheck(
                            pending: Defaults[.pendingConflictCategories], answering: useLocalHold.held
                        ),
                        foundDifference: !diffs.isEmpty
                    )
                    conflictCheckRetry.note(outcome, at: Date(), generation: generation)
                    switch outcome {
                    case .dropped:
                        AppLogger.sync.info("[reenable] result discarded — signed out, sync off or locked while in flight")
                    case .resolvedMeanwhile:
                        AppLogger.sync.info("[reenable] result discarded — resolved while in flight")
                    case .conflict(let checked):
                        reenableConflict = ReenableConflict(
                            categories: Array(checked),
                            description: diffs.joined(separator: "\n"),
                            serverIgnoredCourses: serverIgnoredCourses,
                            serverMarkedAssignments: serverMarkedAssignments
                        )
                    case .clear(let checked):
                        Defaults[.pendingConflictCategories].subtract(checked)
                        cloudSyncCoordinator.scheduleTick()
                    }
                }
            } catch {
                conflictCheckRetry.noteFailure(at: Date(), generation: generation)
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
    /// when `conflictCheckRetry` says one is due. Until a check runs, the outbox holds the edits
    /// of its categories.
    func retryOwedConflictCheck() {
        guard conflictCheckRetry.isDue(
            pending: Defaults[.pendingConflictCategories], checking: isCheckingConflicts,
            awaitingAnswer: reenableConflict != nil, now: Date(), generation: authService.loginGeneration
        ) else { return }
        checkPendingConflicts()
    }

    /// When the pending re-enable check is due to run again by itself. One is owed from launch
    /// until a check gives a verdict, and each failure or dropped result doubles the wait before
    /// the next, from `firstDelay` to `maxDelay`: a weak link can answer the revision poll every
    /// few seconds while `/sync/full` times out, and each snapshot costs the server a log row and
    /// pushes its own sync back. A check run from the Settings screens does not wait. The state
    /// is for one sign-in, `generation`: after a sign-out the next account starts as at launch.
    nonisolated struct ConflictCheckRetry: Equatable, Sendable {
        static let firstDelay: TimeInterval = 30
        static let maxDelay: TimeInterval = 30 * 60

        private(set) var generation: Int
        private(set) var owed = true
        private(set) var failures = 0
        private(set) var notBefore: Date?

        init(generation: Int = 0) {
            self.generation = generation
        }

        /// - Parameter generation: `AuthService.loginGeneration` now.
        func isDue(pending: Set<String>, checking: Bool, awaitingAnswer: Bool, now: Date, generation: Int) -> Bool {
            let state = generation == self.generation ? self : Self(generation: generation)
            return state.owed && !pending.isEmpty && !checking && !awaitingAnswer
                && (state.notBefore.map { now >= $0 } ?? true)
        }

        /// - Parameter generation: the login generation the failed check started in.
        mutating func noteFailure(at now: Date, generation: Int) {
            guard adopt(generation) else { return }
            recordFailure(at: now)
        }

        /// A verdict settles what is owed and a dropped result is owed again; a check whose
        /// categories were answered while it ran changes nothing.
        mutating func note(_ outcome: ConflictCheckOutcome, at now: Date, generation: Int) {
            guard adopt(generation) else { return }
            switch outcome {
            case .dropped:
                recordFailure(at: now)
            case .conflict, .clear:
                owed = false
                failures = 0
                notBefore = nil
            case .resolvedMeanwhile:
                break
            }
        }

        /// The dialog was answered, and `pending` is what is left. A category switched back on
        /// while the answered check ran was turned away by the one-at-a-time guard, and the
        /// verdict covered only the categories the check compared, so it is owed a check. With
        /// another dialog up by then, that dialog covers it, and its own answer notes the rest.
        mutating func noteAnswered(
            leaving pending: Set<String>, awaitingAnswer: Bool, saveFailed: Bool = false, at now: Date = Date(),
            generation: Int
        ) {
            guard adopt(generation) else { return }
            // At once, the server would still differ and the same question come back.
            if saveFailed { return recordFailure(at: now) }
            if !pending.isEmpty, !awaitingAnswer { owed = true }
        }

        private mutating func recordFailure(at now: Date) {
            owed = true
            failures += 1
            notBefore = now.addingTimeInterval(min(Self.firstDelay * pow(2, Double(failures - 1)), Self.maxDelay))
        }

        /// A sign-out moves the generation, and the next account starts as at launch: the
        /// departing account's failures would stretch its waits. Returns false for an older
        /// generation, whose result arrived after the next account's and is dropped.
        private mutating func adopt(_ generation: Int) -> Bool {
            guard generation >= self.generation else { return false }
            if generation != self.generation { self = Self(generation: generation) }
            return true
        }
    }

    /// What a finished re-enable check does with its result.
    nonisolated enum ConflictCheckOutcome: Equatable, Sendable {
        /// A sign-out, Sync course information turned off or the lock screen overtook it.
        case dropped
        /// Every category it compared was answered while it ran.
        case resolvedMeanwhile
        /// The categories to ask about.
        case conflict(Set<String>)
        /// The categories to clear, with an outbox tick for the edits they held.
        case clear(Set<String>)
    }

    /// The outcome of a re-enable check that compared `checked`. After a sign-out its diffs compare
    /// the previous account's server state with emptied caches, with sync off there is nothing to
    /// reconcile, and behind the lock screen the caches read as empty. Only categories still pending
    /// count: a resolve that landed mid-check cleared its own and changed the server state behind
    /// these diffs, so asking again repeats a dialog the user has answered.
    nonisolated static func conflictCheckOutcome(
        mayWrite: Bool, checked: Set<String>, stillPending: Set<String>, foundDifference: Bool
    ) -> ConflictCheckOutcome {
        guard mayWrite else { return .dropped }
        let stillChecked = checked.intersection(stillPending)
        guard !stillChecked.isEmpty else { return .resolvedMeanwhile }
        return foundDifference ? .conflict(stillChecked) : .clear(stillChecked)
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

    /// Applies the user's answer to `reenableConflict`, as `answerReenableConflict` orders it.
    /// Keeping local courses awaits every request and asks again on any failure, after the wait a
    /// failed check gets: until a term's upload lands, the server holds none of its courses and the
    /// reset's tombstones hide them on every other device.
    func resolveReenableConflict(keepLocal: Bool) {
        guard let conflict = reenableConflict else { return }
        AppLogger.sync.info("[reenable] resolve: keepLocal=\(keepLocal, privacy: .public) categories=\(conflict.categories, privacy: .public)")
        reenableConflict = nil
        // Keep Local stops at a sign-out: its course requests would go out on the next account's
        // session, the check it asks again for would be left to that account, and the rest would
        // read emptied caches.
        let generation = authService.loginGeneration
        let isCurrent = { [weak self] in self?.authService.loginGeneration == generation }
        let effects = ReenableAnswerEffects(
            isCurrent: isCurrent,
            take: { self.useLocalHold.take($0, keepLocal: $1, from: &Defaults[.pendingConflictCategories]) },
            release: {
                self.useLocalHold.release($0, from: &Defaults[.pendingConflictCategories])
                // The ticks its edits asked for may have come while the hold kept the marks queued.
                self.cloudSyncCoordinator.scheduleTick()
            },
            end: { self.useLocalHold.end($0) },
            dropQueuedEdits: { await self.cloudSyncCoordinator.discardEdits(of: $0, courseIgnores: $1) },
            sendCourses: { try await self.sendLocalCourses(isCurrent: isCurrent) },
            markCoursesForCheck: { self.markCategoryReenabled("courses") },
            queueEdits: { self.queueLocalEdits(of: conflict) },
            takeServerData: {
                Self.dropLocalCopies(for: conflict)
                await self.syncOverridesFromBackend()
            },
            noteAnswered: { saveFailed in
                self.conflictCheckRetry.noteAnswered(
                    leaving: Defaults[.pendingConflictCategories], awaitingAnswer: self.reenableConflict != nil,
                    saveFailed: saveFailed, generation: generation
                )
                self.retryOwedConflictCheck()
            }
        )
        Task { await Self.answerReenableConflict(conflict, keepLocal: keepLocal, effects: effects) }
    }

    /// What an answer to the re-enable dialog does, for `answerReenableConflict` to order.
    struct ReenableAnswerEffects {
        /// Whether the sign-in the dialog was answered under is still the current one.
        let isCurrent: () -> Bool
        /// `UseLocalHold`'s `take`, `release` and `end` on the stored pending list.
        let take: (_ categories: [String], _ keepLocal: Bool) -> Set<String>
        let release: (_ held: Set<String>) -> Void
        let end: (_ held: Set<String>) -> Void
        /// Use Server: `CloudSyncCoordinator.discardEdits(of:courseIgnores:)`.
        let dropQueuedEdits: (_ categories: Set<String>, _ courseIgnores: Bool) async -> Void
        /// Use Local: this device's courses (`keepLocalCourses`), asked about again when they fail.
        let sendCourses: () async throws -> Void
        let markCoursesForCheck: () -> Void
        /// Use Local: this device's colours, names and marks; each task ends once its edit is queued.
        let queueEdits: () -> [Task<Void, Never>]
        /// Use Server: drops this device's copies and runs the sync that takes the server's.
        let takeServerData: () async -> Void
        let noteAnswered: (_ saveFailed: Bool) -> Void
    }

    /// The order of an answer. Use Server drops the queued edits of what it answers first: until a
    /// category leaves the pending list, its check holds its marks in the outbox, and the sync that
    /// takes the server's data leaves a course with a colour or a name queued as it is here. Use
    /// Local keeps what it answers pending until its course requests are done and its other edits
    /// are in the outbox (`UseLocalHold`). After a sign-out, which cleared the pending list, it
    /// writes nothing more, and the hold ends without letting go of anything.
    static func answerReenableConflict(
        _ conflict: ReenableConflict, keepLocal: Bool, effects: ReenableAnswerEffects
    ) async {
        if !keepLocal {
            await effects.dropQueuedEdits(Set(conflict.categories), conflict.serverIgnoredCourses != nil)
        }
        guard effects.isCurrent() else { return }
        let held = effects.take(conflict.categories, keepLocal)
        var coursesSaveFailed = false
        if keepLocal {
            defer { effects.end(held) }
            if conflict.categories.contains("courses") {
                do {
                    try await effects.sendCourses()
                } catch {
                    AppLogger.sync.error("[reenable] keep-local course sync failed (server may be empty): \(error, privacy: .private)")
                    if effects.isCurrent() { effects.markCoursesForCheck() }
                    coursesSaveFailed = true
                }
            }
            guard effects.isCurrent() else { return }
            for task in effects.queueEdits() { await task.value }
            guard effects.isCurrent() else { return }
            effects.release(held)
        } else {
            await effects.takeServerData()
        }
        // After the answer's own requests, which the next check would otherwise read halfway.
        guard effects.isCurrent() else { return }
        effects.noteAnswered(coursesSaveFailed)
    }

    /// Use Local's course requests (`keepLocalCourses`) for every term this device caches, which
    /// stay latched and are stamped as in `deleteBackendCourses`: a sync that read a term mid-way
    /// would un-hide the courses the upload puts back before their deletes.
    private func sendLocalCourses(isCurrent: () -> Bool) async throws {
        guard CourseUploadPolicy.uploadsCourses else { return }
        let terms = SemesterCatalog.availableSemesters().map { semester in
            (semester: semester,
             courses: DataCache.shared.loadCourses(semester: semester)
                + DataCache.shared.loadUserAddedCourses(semester: semester))
        }
        let latched = Set(terms.map(\.semester))
        resettingSemesters.formUnion(latched)
        defer {
            resettingSemesters.subtract(latched)
            for semester in latched { DataCache.shared.recordSemesterReset(semester) }
        }
        try await Self.keepLocalCourses(
            terms, hiding: Set(DataCache.shared.loadDeletedCourseNos()), on: pushCoordinator, isCurrent: isCurrent
        )
    }

    /// Use Local's colours, names and marks, from this device's copies, and the tasks that queue them.
    private func queueLocalEdits(of conflict: ReenableConflict) -> [Task<Void, Never>] {
        var queued: [Task<Void, Never>?] = []
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
                    queued += syncCourseOverride(moodleCourseId: moodleId, colorHex: String(format: "#%06X", hex))
                }
            }
            if conflict.categories.contains("course_names") {
                let customNames = DataCache.shared.loadCourseCustomNames()
                for (courseNo, locales) in customNames {
                    guard let moodleId = moodleIdByCourseNo[courseNo] else { continue }
                    for (locale, name) in locales where !name.isEmpty {
                        queued += syncCourseOverride(moodleCourseId: moodleId, customName: name, locale: locale)
                    }
                }
            }
        }
        if conflict.categories.contains("assignments") {
            let archived = DataCache.shared.loadArchivedAssignmentIds()
            let completed = DataCache.shared.loadLocallyCompletedAssignmentIds()
            for id in archived {
                queued.append(syncAssignmentOverride(moodleId: id, status: "archived"))
            }
            for id in completed {
                queued.append(syncAssignmentOverride(moodleId: id, status: "locally_completed"))
            }
            let cleared = Self.assignmentMarksToClear(
                server: conflict.serverMarkedAssignments, local: archived.union(completed)
            )
            for id in cleared {
                queued.append(syncAssignmentOverride(moodleId: id, status: "none"))
            }
            if let serverIgnoredCourses = conflict.serverIgnoredCourses {
                let ignoredCourses = DataCache.shared.loadIgnoredAssignmentCourses()
                queued += syncCourseIgnores(ignoredCourses)
                for course in Self.courseIgnoresToClear(server: serverIgnoredCourses, local: ignoredCourses) {
                    queued.append(syncCourseIgnore(
                        semester: course.semester, courseNo: course.courseNo,
                        moodleIdNumber: course.moodleId, ignore: false
                    ))
                }
            }
        }
        return queued.compactMap { $0 }
    }

    /// The pending categories a re-enable check compares: all but those a Use Local answer still
    /// keeps pending (`answering`, `UseLocalHold.held`), which it sends itself. Asking about one
    /// again would repeat the question the user has answered.
    nonisolated static func categoriesToCheck(pending: Set<String>, answering: Set<String>) -> Set<String> {
        pending.subtracting(answering)
    }

    /// The categories running Use Local answers keep on the pending list until their course
    /// requests are done and their other edits queued, and which of those were switched back on
    /// meanwhile. A full sync meanwhile would take the server's data of them, which the answer
    /// would send back, and an app ended between the courses' upload and their deletes would show
    /// the hidden courses again on every device; pending, they are asked about after the relaunch.
    /// In memory: after a relaunch no answer runs.
    nonisolated struct UseLocalHold: Equatable, Sendable {
        /// What the re-enable check skips (`categoriesToCheck`): the answers send it themselves.
        private(set) var held: Set<String> = []
        private var reenabled: Set<String> = []

        /// The tap: Use Server takes the answered `categories` off `pending`, and Use Local holds
        /// them, which it returns. Only those: a category switched back on after the check started
        /// was not in the dialog, and stays pending for the next check to ask about.
        mutating func take(_ categories: [String], keepLocal: Bool, from pending: inout Set<String>) -> Set<String> {
            guard keepLocal else {
                pending.subtract(categories)
                return []
            }
            held.formUnion(categories)
            return Set(categories)
        }

        /// A held category switched off and on again: its switch asks for a check of its own.
        mutating func noteReenabled(_ category: String) {
            if held.contains(category) { reenabled.insert(category) }
        }

        /// The answer is done with `kept`: it leaves `pending`, but for what was switched back on meanwhile.
        mutating func release(_ kept: Set<String>, from pending: inout Set<String>) {
            pending.subtract(kept.subtracting(reenabled))
            end(kept)
        }

        mutating func end(_ kept: Set<String>) {
            held.subtract(kept)
            reenabled.subtract(kept)
        }
    }

    /// What Use Server drops on this device so the full sync after it takes the server's data.
    /// Hidden courses stay: that sync takes the server's list in each term it lists, and a term it
    /// lists none in, which the check did not compare, keeps this device's.
    static func dropLocalCopies(for conflict: ReenableConflict, in cache: DataCache = .shared) {
        if conflict.categories.contains("course_colors") {
            cache.saveCourseColorMap([:])
            // The theme follows the shared cache, which every caller but a test passes.
            TigerDuckTheme.reload()
        }
        if conflict.categories.contains("course_names") {
            cache.saveCourseCustomNames([:])
        }
        if conflict.categories.contains("assignments") {
            cache.replaceArchivedAssignmentIds([])
            cache.replaceLocallyCompletedAssignmentIds([])
            if conflict.serverIgnoredCourses != nil {
                cache.replaceIgnoredAssignmentCourses([])
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
                try await backend.deleteCourse(courseKey: CourseTombstone.serverKey(semester: semester, courseNo: courseNo))
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
