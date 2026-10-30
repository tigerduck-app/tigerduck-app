import SwiftUI
import SwiftData
import Defaults
import os

extension AppState {

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
        var serverIgnoredCourses: [ServerIgnoredCourse]?
        let serverMarkedAssignments: Set<String>
    }

    func markCategoryReenabled(_ category: String) {
        pushCoordinator.forgetUploads()
        Self.markForReenableCheck(category, signedIn: authService.hasStoredCredentials)
        useLocalHold.noteReenabled(category)
    }

    static func markForReenableCheck(_ category: String, signedIn: Bool) {
        let synced = hasSynced(category)
        guard signedIn, synced else {
            AppLogger.sync.info("[reenable] not marked: \(category, privacy: .public), signedIn=\(signedIn, privacy: .public) synced=\(synced, privacy: .public)")
            return
        }
        Defaults[.pendingConflictCategories].insert(category)
        AppLogger.sync.info("[reenable] marked category: \(category, privacy: .public), pending=\(Defaults[.pendingConflictCategories].sorted(), privacy: .public)")
    }

    static func hasSynced(_ category: String) -> Bool {
        Defaults[.categoriesSyncedOnce].contains(category)
    }

    static let reenableCategories: Set<String> = ["courses", "course_colors", "course_names", "assignments"]

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
        if !isRetry {
            guard !isCheckingConflicts else {
                AppLogger.sync.info("[reenable] checkPendingConflicts skipped — already in flight")
                return
            }
            isCheckingConflicts = true
        }
        AppLogger.sync.info("[reenable] checkPendingConflicts start: pending=\(pending.sorted(), privacy: .public)")
        Task {
            var handedOffToRetry = false
            defer {
                if !handedOffToRetry {
                    Task { @MainActor in self.endConflictCheck(checked: pending, startedIn: generation) }
                }
            }
            do {
                let (json, courseDeletes) = try await cloudSyncCoordinator.courseDeletes(around: {
                    try await pushCoordinator.fetchFullSync()
                })
                var diffs: [String] = []
                var serverMarkedAssignments = Set<String>()

                let coursesArray = json["courses"] as? [[String: Any]] ?? []
                let serverIgnoredCourses = Self.serverIgnoredCourses(
                    json["course_overrides"] as? [[String: Any]] ?? [], syncsCourses: Defaults[.syncCourses]
                )

                if pending.contains("courses") {
                    let deletedNos = Set(DataCache.shared.loadDeletedCourseNos())
                    let userAdded = DataCache.shared.loadUserAddedCourses()
                    let serverSemesters = coursesArray.compactMap { $0["semester"] as? String }.filter { !$0.isEmpty }
                    var localOnly = 0
                    var serverOnly = 0
                    for semester in Set(serverSemesters).union(SemesterCatalog.availableSemesters()) {
                        let serverNos = Self.serverCourseNos(coursesArray, semester: semester, userAdded: userAdded)
                        let localNos = Set(DataCache.shared.loadCourses(semester: semester).map(\.courseNo))
                            .union(DataCache.shared.loadUserAddedCourses(semester: semester).map(\.courseNo))
                            .filter { !CourseTombstone.isHidden($0, semester: semester, in: deletedNos) }
                        guard let counts = Self.coursesOnOneSide(
                            server: serverNos, local: localNos, semester: semester, deleting: courseDeletes
                        ) else { continue }
                        localOnly += counts.localOnly
                        serverOnly += counts.serverOnly
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
                        let nameMismatches = Self.courseNameMismatches(
                            overrides, courseNos: moodleIdToNo, local: DataCache.shared.loadCourseCustomNames()
                        )
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
                if case PushAPIError.httpStatus(401, _, let sent) = error, retriesLeft > 0 {
                    let reloginOk = await attemptBackendRelogin(replacing: sent?.value)
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

    /// A server name of `""` is a cleared one, as `courseNamesAfterPull` reads it.
    nonisolated static func courseNameMismatches(
        _ overrides: [[String: Any]], courseNos: [String: String], local: [String: [String: String]]
    ) -> [String] {
        var mismatches: [String] = []
        var serverNosWithNames = Set<String>()
        for o in overrides {
            guard let mId = o["moodle_id"] as? String ?? (o["moodle_id"] as? Int).map(String.init),
                  let courseNo = courseNos[mId],
                  let serverNames = (o["custom_names"] as? [String: String])?.filter({ !$0.value.isEmpty }),
                  !serverNames.isEmpty else { continue }
            serverNosWithNames.insert(courseNo)
            if (local[courseNo] ?? [:]) != serverNames {
                mismatches.append("\(courseNo): local=\(local[courseNo] ?? [:]) server=\(serverNames)")
            }
        }
        for (courseNo, locales) in local where !locales.isEmpty && !serverNosWithNames.contains(courseNo) {
            mismatches.append("\(courseNo): local=\(locales) server=default")
        }
        return mismatches
    }

    nonisolated static func coursesOnOneSide(
        server: Set<String>, local: Set<String>, semester: String, deleting: Set<String>
    ) -> (localOnly: Int, serverOnly: Int)? {
        let server = server.filter { !CourseTombstone.isHidden($0, semester: semester, in: deleting) }
        guard !server.isEmpty, !local.isEmpty else { return nil }
        return (local.subtracting(server).count, server.subtracting(local).count)
    }

    private func endConflictCheck(checked pending: Set<String>, startedIn generation: Int) {
        isCheckingConflicts = false
        let unchecked = Self.categoriesLeftToCheck(
            pending: Defaults[.pendingConflictCategories], checked: pending,
            signedOutSince: generation != authService.loginGeneration
        )
        if reenableConflict == nil, !unchecked.isEmpty {
            checkPendingConflicts()
        }
    }

    func retryOwedConflictCheck() {
        guard conflictCheckRetry.isDue(
            pending: Defaults[.pendingConflictCategories], checking: isCheckingConflicts,
            awaitingAnswer: reenableConflict != nil, now: Date(), generation: authService.loginGeneration
        ) else { return }
        checkPendingConflicts()
    }

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

        func isDue(pending: Set<String>, checking: Bool, awaitingAnswer: Bool, now: Date, generation: Int) -> Bool {
            let state = generation == self.generation ? self : Self(generation: generation)
            return state.owed && !pending.isEmpty && !checking && !awaitingAnswer
                && (state.notBefore.map { now >= $0 } ?? true)
        }

        mutating func noteFailure(at now: Date, generation: Int) {
            guard adopt(generation) else { return }
            recordFailure(at: now)
        }

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

        mutating func noteAnswered(
            leaving pending: Set<String>, awaitingAnswer: Bool, saveFailed: Bool = false, at now: Date = Date(),
            generation: Int
        ) {
            guard adopt(generation) else { return }
            if saveFailed { return recordFailure(at: now) }
            if !pending.isEmpty, !awaitingAnswer { owed = true }
        }

        private mutating func recordFailure(at now: Date) {
            owed = true
            failures += 1
            notBefore = now.addingTimeInterval(min(Self.firstDelay * pow(2, Double(failures - 1)), Self.maxDelay))
        }

        private mutating func adopt(_ generation: Int) -> Bool {
            guard generation >= self.generation else { return false }
            if generation != self.generation { self = Self(generation: generation) }
            return true
        }
    }

    nonisolated enum ConflictCheckOutcome: Equatable, Sendable {
        case dropped
        case resolvedMeanwhile
        case conflict(Set<String>)
        case clear(Set<String>)
    }

    nonisolated static func conflictCheckOutcome(
        mayWrite: Bool, checked: Set<String>, stillPending: Set<String>, foundDifference: Bool
    ) -> ConflictCheckOutcome {
        guard mayWrite else { return .dropped }
        let stillChecked = checked.intersection(stillPending)
        guard !stillChecked.isEmpty else { return .resolvedMeanwhile }
        return foundDifference ? .conflict(stillChecked) : .clear(stillChecked)
    }

    nonisolated static func categoriesLeftToCheck(
        pending: Set<String>, checked: Set<String>, signedOutSince: Bool
    ) -> Set<String> {
        signedOutSince ? pending : pending.subtracting(checked)
    }

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

    func resolveReenableConflict(keepLocal: Bool) {
        guard let conflict = reenableConflict else { return }
        AppLogger.sync.info("[reenable] resolve: keepLocal=\(keepLocal, privacy: .public) categories=\(conflict.categories, privacy: .public)")
        reenableConflict = nil
        let generation = authService.loginGeneration
        let isCurrent = { [weak self] in self?.authService.loginGeneration == generation }
        let effects = ReenableAnswerEffects(
            isCurrent: isCurrent,
            take: { self.useLocalHold.take($0, keepLocal: $1, from: &Defaults[.pendingConflictCategories]) },
            release: {
                self.useLocalHold.release($0, from: &Defaults[.pendingConflictCategories])
                self.cloudSyncCoordinator.scheduleTick()
            },
            end: { self.useLocalHold.end($0) },
            dropQueuedEdits: { await self.cloudSyncCoordinator.discardEdits(of: $0, courseIgnores: $1) },
            sendCourses: { try await self.sendLocalCourses(isCurrent: isCurrent) },
            markCoursesForCheck: { self.markCategoryReenabled("courses") },
            queueEdits: { self.queueLocalEdits(of: conflict) },
            dropLocalCopies: { Self.dropLocalCopies(for: conflict) },
            syncFromServer: { await self.syncOverridesFromBackend(followUpIfBusy: $0) },
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

    struct ReenableAnswerEffects {
        let isCurrent: () -> Bool
        let take: (_ categories: [String], _ keepLocal: Bool) -> Set<String>
        let release: (_ held: Set<String>) -> Void
        let end: (_ held: Set<String>) -> Void
        let dropQueuedEdits: (_ categories: Set<String>, _ courseIgnores: Bool) async -> Void
        let sendCourses: () async throws -> Void
        let markCoursesForCheck: () -> Void
        let queueEdits: () -> [Task<Void, Never>]
        let dropLocalCopies: () -> Void
        let syncFromServer: (_ followUpIfBusy: Bool) async -> Void
        let noteAnswered: (_ saveFailed: Bool) -> Void
    }

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
            effects.dropLocalCopies()
            await effects.syncFromServer(true)
        }
        guard effects.isCurrent() else { return }
        effects.noteAnswered(coursesSaveFailed)
    }

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

    private func queueLocalEdits(of conflict: ReenableConflict) -> [Task<Void, Never>] {
        var queued: [Task<Void, Never>?] = []
        if conflict.categories.contains("course_colors") || conflict.categories.contains("course_names") {
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

    nonisolated static func categoriesToCheck(pending: Set<String>, answering: Set<String>) -> Set<String> {
        pending.subtracting(answering)
    }

    nonisolated struct UseLocalHold: Equatable, Sendable {
        private(set) var held: Set<String> = []
        private var reenabled: Set<String> = []

        mutating func take(_ categories: [String], keepLocal: Bool, from pending: inout Set<String>) -> Set<String> {
            guard keepLocal else {
                pending.subtract(categories)
                return []
            }
            held.formUnion(categories)
            return Set(categories)
        }

        mutating func noteReenabled(_ category: String) {
            if held.contains(category) { reenabled.insert(category) }
        }

        mutating func release(_ kept: Set<String>, from pending: inout Set<String>) {
            pending.subtract(kept.subtracting(reenabled))
            end(kept)
        }

        mutating func end(_ kept: Set<String>) {
            held.subtract(kept)
            reenabled.subtract(kept)
        }
    }

    static func dropLocalCopies(for conflict: ReenableConflict, in cache: DataCache = .shared) {
        if conflict.categories.contains("course_colors") {
            cache.saveCourseColorMap([:])
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

protocol CourseSyncBackend {
    func deleteAllCourses(semester: String?) async throws
    func uploadCourses(_ request: PushAPI.CourseUploadRequest) async throws
    func deleteCourse(courseKey: String) async throws
}

extension PushCoordinator: CourseSyncBackend {}
