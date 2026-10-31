import Defaults
import Foundation
import os
import SwiftUI

/// The questions TigerSync asks the user: marks the two sides disagree on, and categories switched
/// back on whose local and server copies differ.
@MainActor
@Observable
final class SyncConflicts {
    var reenableConflict: ReenableConflict?
    @ObservationIgnored private unowned let app: AppEnvironment
    @ObservationIgnored let marks: MarkConflicts
    @ObservationIgnored private var isCheckingConflicts = false
    @ObservationIgnored private(set) var conflictCheckRetry = ConflictCheckRetry()
    @ObservationIgnored private var useLocalHold = UseLocalHold()

    init(app: AppEnvironment) {
        self.app = app
        marks = MarkConflicts(app: app)
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

    var syncConflicts: [SyncConflictItem] {
        get { marks.items }
        set { marks.items = newValue }
    }

    var syncConflictAlertMessage: String { marks.alertMessage }

    func resolveSyncConflicts(keepLocal: Bool) {
        marks.resolve(keepLocal: keepLocal)
    }

    var alertIsPresented: Binding<Bool> { marks.alertIsPresented }

    static func syncConflictAlertIsPresented(_ conflicts: Binding<[SyncConflictItem]>) -> Binding<Bool> {
        MarkConflicts.alertIsPresented(conflicts)
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
                let found = ReenableDifferences.find(
                    in: json, checking: pending, courseDeletes: courseDeletes,
                    studentId: { app.authService.storedStudentId }
                )
                await MainActor.run {
                    let outcome = Self.conflictCheckOutcome(
                        mayWrite: app.fullSync.mayWrite(since: ticket), checked: pending,
                        stillPending: Self.categoriesToCheck(
                            pending: Defaults[.pendingConflictCategories], answering: useLocalHold.held
                        ),
                        foundDifference: !found.lines.isEmpty
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
                            description: found.lines.joined(separator: "\n"),
                            serverIgnoredCourses: found.serverIgnoredCourses,
                            serverMarkedAssignments: found.serverMarkedAssignments
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

    nonisolated static func courseNameMismatches(
        _ overrides: [[String: Any]], courseNos: [String: String], local: [String: [String: String]]
    ) -> [String] {
        ReenableDifferences.courseNameMismatches(overrides, courseNos: courseNos, local: local)
    }

    nonisolated static func coursesOnOneSide(
        server: Set<String>, local: Set<String>, semester: String, deleting: Set<String>
    ) -> (localOnly: Int, serverOnly: Int)? {
        ReenableDifferences.coursesOnOneSide(server: server, local: local, semester: semester, deleting: deleting)
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

    /// Whether the re-enable alert shows; closing it unanswered drops the conflict.
    var reenableAlertIsPresented: Binding<Bool> {
        Self.reenableAlertIsPresented(Bindable(self).reenableConflict)
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
            sendCourses: {
                try await ReenableAnswer.sendLocalCourses(
                    localEdits: self.app.localEdits, push: self.app.pushCoordinator, isCurrent: isCurrent
                )
            },
            markCoursesForCheck: { self.markCategoryReenabled("courses") },
            queueEdits: { ReenableAnswer.queueLocalEdits(of: conflict, edits: self.app.edits) },
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

    typealias ReenableAnswerEffects = ReenableAnswer.Effects

    static func answerReenableConflict(
        _ conflict: ReenableConflict, keepLocal: Bool, effects: ReenableAnswerEffects
    ) async {
        await ReenableAnswer.answer(conflict, keepLocal: keepLocal, effects: effects)
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
        ReenableAnswer.dropLocalCopies(for: conflict, courses: courses, assignments: assignments, colors: colors)
    }

    static func keepLocalCourses(
        _ terms: [(semester: String, courses: [SDCourse])], hiding deletedNos: Set<String>,
        on backend: some CourseSyncBackend, isCurrent: () -> Bool = { true }
    ) async throws {
        try await ReenableAnswer.keepLocalCourses(terms, hiding: deletedNos, on: backend, isCurrent: isCurrent)
    }
}

protocol CourseSyncBackend {
    func deleteAllCourses(semester: String?, madeAt: Date) async throws
    func uploadCourses(_ request: PushAPI.CourseUploadRequest, addedAt: Date?) async throws
    func deleteCourse(courseKey: String, madeAt: Date) async throws
}

extension PushCoordinator: CourseSyncBackend {}
