import Defaults
import Foundation
import os
import SwiftUI

/// The questions TigerSync asks the user: marks the two sides disagree on, and categories switched
/// back on whose local and server copies differ.
@MainActor
@Observable
final class SyncConflicts {
    var syncConflicts: [SyncConflictItem] = []
    var reenableConflict: ReenableConflict?
    @ObservationIgnored private unowned let app: AppEnvironment
    @ObservationIgnored private var isCheckingConflicts = false
    @ObservationIgnored private(set) var conflictCheckRetry = ConflictCheckRetry()
    @ObservationIgnored private var useLocalHold = UseLocalHold()

    init(app: AppEnvironment) {
        self.app = app
    }

    struct SyncConflictItem: Identifiable {
        let id: String
        let kind: String
        let label: String
        let localStatus: String
        let serverStatus: String

        var localLabel: String { Self.statusLabel(localStatus) }
        var serverLabel: String { Self.statusLabel(serverStatus) }

        private static func statusLabel(_ status: String) -> String {
            switch status {
            case "ignored", "archived": return String(localized: "sync_conflict_status_ignored")
            case "locally_completed": return String(localized: "sync_conflict_status_completed")
            default: return String(localized: "sync_conflict_status_none")
            }
        }
    }

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
                app.edits.syncAssignmentOverride(moodleId: c.id, status: c.localStatus)
            }
        } else {
            let coordinator = app.cloudSyncCoordinator
            let push = app.pushCoordinator
            let isCurrent = app.authService.session.currentCheck()
            Task { [weak self] in
                await AssignmentMarksReconciler.keepServerSide(
                    read: { ServerMarks(try await push.fetchFullSync()) },
                    protected: { [weak self] in
                        await coordinator.pendingAssignmentOverrideIds().union(self?.app.localEdits.pendingOverrides ?? [])
                    },
                    isCurrent: isCurrent,
                    assignments: .shared
                )
            }
        }
        syncConflicts = []
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
        var serverIgnoredCourses: [CourseIgnoresReconciler.ServerIgnoredCourse]?
        let serverMarkedAssignments: Set<String>
    }

    func markCategoryReenabled(_ category: String) {
        app.pushCoordinator.forgetUploads()
        Self.markForReenableCheck(category, signedIn: app.authService.hasStoredCredentials)
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
        SyncPolicy.current.switchedOn
    }

    func checkPendingConflicts() {
        let pending = Self.categoriesToCheck(
            pending: Defaults[.pendingConflictCategories], answering: useLocalHold.held
        )
        let ticket = app.authService.session.ticket
        guard !pending.isEmpty, Defaults[.cloudSyncEnabled] else {
            AppLogger.sync.info("[reenable] checkPendingConflicts skip: pending=\(Defaults[.pendingConflictCategories].sorted(), privacy: .public) syncEnabled=\(Defaults[.cloudSyncEnabled], privacy: .public)")
            return
        }
        guard !isCheckingConflicts else {
            AppLogger.sync.info("[reenable] checkPendingConflicts skipped — already in flight")
            return
        }
        isCheckingConflicts = true
        AppLogger.sync.info("[reenable] checkPendingConflicts start: pending=\(pending.sorted(), privacy: .public)")
        Task {
            defer {
                Task { @MainActor in self.endConflictCheck(checked: pending, startedIn: ticket) }
            }
            do {
                let (json, courseDeletes) = try await app.cloudSyncCoordinator.courseDeletes(around: {
                    try await app.pushCoordinator.fetchFullSync()
                })
                var diffs: [String] = []
                var serverMarkedAssignments = Set<String>()

                let coursesArray = json["courses"] as? [[String: Any]] ?? []
                let serverIgnoredCourses = CourseIgnoresReconciler.serverIgnoredCourses(
                    json["course_overrides"] as? [[String: Any]] ?? [], syncsCourses: Defaults[.syncCourses]
                )

                if pending.contains("courses") {
                    let deletedNos = Set(CourseStore.shared.loadDeletedCourseNos())
                    let userAdded = CourseStore.shared.loadUserAddedCourses()
                    let studentId = app.authService.storedStudentId
                    let serverSemesters = coursesArray.compactMap { $0["semester"] as? String }.filter { !$0.isEmpty }
                    var localOnly = 0
                    var serverOnly = 0
                    for semester in Set(serverSemesters).union(SemesterCatalog.availableSemesters()) {
                        let (serverNos, localNos) = CourseRosterReconciler.reenableCourseNos(
                            coursesArray, semester: semester,
                            local: Set(CourseStore.shared.loadCourses(semester: semester).map(\.courseNo))
                                .union(CourseStore.shared.loadUserAddedCourses(semester: semester).map(\.courseNo))
                                .filter { !CourseTombstone.isHidden($0, semester: semester, in: deletedNos) },
                            userAdded: userAdded,
                            liveAnswer: studentId.flatMap { CourseSelectionService.lastAnswer(studentId: $0, semester: semester) }
                        )
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
                        guard let mId = CourseOverridesReconciler.overrideIdentity(c) else { continue }
                        if let courseNo = c["course_no"] as? String, !courseNo.isEmpty {
                            moodleIdToNo[mId] = courseNo
                        }
                    }
                    AppLogger.sync.info("[reenable] overrides=\(overrides.count, privacy: .public) moodleIdMap=\(moodleIdToNo.count, privacy: .public)")

                    if pending.contains("course_colors") {
                        let localColorMap = TigerDuckTheme.courseColorMap
                        var colorMismatches: [String] = []
                        for o in overrides {
                            guard let mId = CourseOverridesReconciler.overrideIdentity(o),
                                  let courseNo = o["course_no"] as? String ?? moodleIdToNo[mId],
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
                            overrides, courseNos: moodleIdToNo, local: CourseStore.shared.loadCourseCustomNames()
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
                    let localArchivedIds = AssignmentStore.shared.loadArchivedAssignmentIds()
                    let localCompletedIds = AssignmentStore.shared.loadLocallyCompletedAssignmentIds()
                    let archivedMatch = localArchivedIds == serverArchivedIds
                    let completedMatch = localCompletedIds == serverCompletedIds
                    let coursesDiffer = CourseIgnoresReconciler.ignoredCoursesDiffer(
                        server: serverIgnoredCourses.map { Set($0.map(\.key)) },
                        decided: CourseIgnoresReconciler.serverDecidedCourses(json["course_overrides"] as? [[String: Any]] ?? [])
                            .union(CourseIgnoresReconciler.recreatedCourses(
                                listed: CourseIgnoresReconciler.listedCourseRows(coursesArray), seen: Defaults[.courseRowIdsSeen]
                            )),
                        listed: CourseIgnoresReconciler.listedCourses(coursesArray),
                        local: AssignmentStore.shared.loadIgnoredAssignmentCourses(),
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
                        mayWrite: app.fullSync.mayWrite(since: ticket), checked: pending,
                        stillPending: Self.categoriesToCheck(
                            pending: Defaults[.pendingConflictCategories], answering: useLocalHold.held
                        ),
                        foundDifference: !diffs.isEmpty
                    )
                    conflictCheckRetry.note(outcome, at: Date(), signIn: ticket)
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
                        app.cloudSyncCoordinator.scheduleTick()
                    }
                }
            } catch {
                conflictCheckRetry.noteFailure(at: Date(), signIn: ticket)
                AppLogger.sync.error("[reenable] checkPendingConflicts FAILED: \(error, privacy: .private) — pending kept for retry")
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
            guard let mId = CourseOverridesReconciler.overrideIdentity(o),
                  let courseNo = o["course_no"] as? String ?? courseNos[mId],
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

    private func endConflictCheck(checked pending: Set<String>, startedIn ticket: AccountSession.Ticket) {
        isCheckingConflicts = false
        let unchecked = Self.categoriesLeftToCheck(
            pending: Defaults[.pendingConflictCategories], checked: pending,
            signedOutSince: !app.authService.session.isCurrent(ticket)
        )
        if reenableConflict == nil, !unchecked.isEmpty {
            checkPendingConflicts()
        }
    }

    func retryOwedConflictCheck() {
        guard conflictCheckRetry.isDue(
            pending: Defaults[.pendingConflictCategories], checking: isCheckingConflicts,
            awaitingAnswer: reenableConflict != nil, now: Date(), signIn: app.authService.session.ticket
        ) else { return }
        checkPendingConflicts()
    }

    nonisolated struct ConflictCheckRetry: Equatable, Sendable {
        static let firstDelay: TimeInterval = 30
        static let maxDelay: TimeInterval = 30 * 60

        private(set) var signIn: AccountSession.Ticket?
        private(set) var owed = true
        private(set) var failures = 0
        private(set) var notBefore: Date?

        init(signIn: AccountSession.Ticket? = nil) {
            self.signIn = signIn
        }

        func isDue(
            pending: Set<String>, checking: Bool, awaitingAnswer: Bool, now: Date, signIn: AccountSession.Ticket
        ) -> Bool {
            let state = signIn == self.signIn ? self : Self(signIn: signIn)
            return state.owed && !pending.isEmpty && !checking && !awaitingAnswer
                && (state.notBefore.map { now >= $0 } ?? true)
        }

        mutating func noteFailure(at now: Date, signIn: AccountSession.Ticket) {
            guard adopt(signIn) else { return }
            recordFailure(at: now)
        }

        mutating func note(_ outcome: ConflictCheckOutcome, at now: Date, signIn: AccountSession.Ticket) {
            guard adopt(signIn) else { return }
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
            signIn: AccountSession.Ticket
        ) {
            guard adopt(signIn) else { return }
            if saveFailed { return recordFailure(at: now) }
            if !pending.isEmpty, !awaitingAnswer { owed = true }
        }

        private mutating func recordFailure(at now: Date) {
            owed = true
            failures += 1
            notBefore = now.addingTimeInterval(min(Self.firstDelay * pow(2, Double(failures - 1)), Self.maxDelay))
        }

        private mutating func adopt(_ signIn: AccountSession.Ticket) -> Bool {
            if let current = self.signIn, signIn < current { return false }
            if signIn != self.signIn { self = Self(signIn: signIn) }
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
        let ticket = app.authService.session.ticket
        let isCurrent = { [weak self] in self?.app.authService.session.isCurrent(ticket) == true }
        let effects = ReenableAnswerEffects(
            isCurrent: isCurrent,
            take: { self.useLocalHold.take($0, keepLocal: $1, from: &Defaults[.pendingConflictCategories]) },
            release: {
                self.useLocalHold.release($0, from: &Defaults[.pendingConflictCategories])
                self.app.cloudSyncCoordinator.scheduleTick()
            },
            end: { self.useLocalHold.end($0) },
            dropQueuedEdits: { await self.app.cloudSyncCoordinator.discardEdits(of: $0, courseIgnores: $1) },
            sendCourses: { try await self.sendLocalCourses(isCurrent: isCurrent) },
            markCoursesForCheck: { self.markCategoryReenabled("courses") },
            queueEdits: { self.queueLocalEdits(of: conflict) },
            dropLocalCopies: { Self.dropLocalCopies(for: conflict) },
            syncFromServer: { await self.app.fullSync.sync(followUpIfBusy: $0) },
            noteAnswered: { saveFailed in
                self.conflictCheckRetry.noteAnswered(
                    leaving: Defaults[.pendingConflictCategories], awaitingAnswer: self.reenableConflict != nil,
                    saveFailed: saveFailed, signIn: ticket
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
        guard SyncPolicy.current.uploadsCourses else { return }
        let terms = SemesterCatalog.availableSemesters().map { semester in
            (semester: semester,
             courses: CourseStore.shared.loadCourses(semester: semester)
                + CourseStore.shared.loadUserAddedCourses(semester: semester))
        }
        let latched = Set(terms.map(\.semester))
        app.localEdits.resettingSemesters.formUnion(latched)
        defer {
            app.localEdits.resettingSemesters.subtract(latched)
            for semester in latched { CourseStore.shared.recordSemesterReset(semester) }
        }
        try await Self.keepLocalCourses(
            terms, hiding: Set(CourseStore.shared.loadDeletedCourseNos()), on: app.pushCoordinator, isCurrent: isCurrent
        )
    }

    private func queueLocalEdits(of conflict: ReenableConflict) -> [Task<Void, Never>] {
        var queued: [Task<Void, Never>?] = []
        if conflict.categories.contains("course_colors") || conflict.categories.contains("course_names") {
            let terms = SemesterCatalog.availableSemesters().map { ($0, CourseStore.shared.loadCourses(semester: $0)) }
            let moodleIdByCourseNo = Dictionary(
                terms.flatMap(\.1).compactMap { c in c.moodleIdNumber.map { (c.courseNo, $0) } },
                uniquingKeysWith: { first, _ in first })
            if conflict.categories.contains("course_colors") {
                let identities = terms.flatMap { term in
                    term.1.map { ($0.courseNo, EditSender.colorIdentity(of: $0, semester: term.0)) }
                }
                let identityByCourseNo = moodleIdByCourseNo.merging(identities, uniquingKeysWith: { first, _ in first })
                let colorMap = TigerDuckTheme.courseColorMap
                for (courseNo, hex) in colorMap {
                    guard let identity = identityByCourseNo[courseNo] else { continue }
                    queued += app.edits.syncCourseOverride(moodleCourseId: identity, colorHex: String(format: "#%06X", hex))
                }
            }
            if conflict.categories.contains("course_names") {
                let customNames = CourseStore.shared.loadCourseCustomNames()
                for (courseNo, locales) in customNames {
                    guard let moodleId = moodleIdByCourseNo[courseNo] else { continue }
                    for (locale, name) in locales where !name.isEmpty {
                        queued += app.edits.syncCourseOverride(moodleCourseId: moodleId, customName: name, locale: locale)
                    }
                }
            }
        }
        if conflict.categories.contains("assignments") {
            let archived = AssignmentStore.shared.loadArchivedAssignmentIds()
            let completed = AssignmentStore.shared.loadLocallyCompletedAssignmentIds()
            for id in archived {
                queued.append(app.edits.syncAssignmentOverride(moodleId: id, status: "archived"))
            }
            for id in completed {
                queued.append(app.edits.syncAssignmentOverride(moodleId: id, status: "locally_completed"))
            }
            let cleared = AssignmentMarksReconciler.assignmentMarksToClear(
                server: conflict.serverMarkedAssignments, local: archived.union(completed)
            )
            for id in cleared {
                queued.append(app.edits.syncAssignmentOverride(moodleId: id, status: "none"))
            }
            if let serverIgnoredCourses = conflict.serverIgnoredCourses {
                let ignoredCourses = AssignmentStore.shared.loadIgnoredAssignmentCourses()
                queued += app.edits.syncCourseIgnores(ignoredCourses)
                for course in CourseIgnoresReconciler.courseIgnoresToClear(server: serverIgnoredCourses, local: ignoredCourses) {
                    queued.append(app.edits.syncCourseIgnore(
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

    static func dropLocalCopies(
        for conflict: ReenableConflict, courses: CourseStore = .shared, assignments: AssignmentStore = .shared,
        colors: CourseColorFiles = CourseColorStore.shared.files
    ) {
        if conflict.categories.contains("course_colors") {
            colors.saveCourseColorMap([:])
            TigerDuckTheme.reload()
        }
        if conflict.categories.contains("course_names") {
            courses.saveCourseCustomNames([:])
        }
        if conflict.categories.contains("assignments") {
            assignments.replaceArchivedAssignmentIds([])
            assignments.replaceLocallyCompletedAssignmentIds([])
            if conflict.serverIgnoredCourses != nil {
                assignments.replaceIgnoredAssignmentCourses([])
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
                try await backend.deleteAllCourses(semester: semester, madeAt: Date())
            }
            guard isCurrent() else { throw CancellationError() }
            try await backend.uploadCourses(SchoolDataUploader.courseUploadRequest(courses + stubs, semester: semester), addedAt: nil)
            for courseNo in hiddenNos.sorted() {
                guard isCurrent() else { throw CancellationError() }
                try await backend.deleteCourse(
                    courseKey: CourseTombstone.serverKey(semester: semester, courseNo: courseNo), madeAt: Date()
                )
            }
        }
    }
}

protocol CourseSyncBackend {
    func deleteAllCourses(semester: String?, madeAt: Date) async throws
    func uploadCourses(_ request: PushAPI.CourseUploadRequest, addedAt: Date?) async throws
    func deleteCourse(courseKey: String, madeAt: Date) async throws
}

extension PushCoordinator: CourseSyncBackend {}
