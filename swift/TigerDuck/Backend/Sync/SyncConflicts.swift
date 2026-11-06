import Defaults
import Foundation
import os
import SwiftUI

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
        let categories: [SyncCategory]
        let description: String
        var serverIgnoredCourses: [CourseIgnoresReconciler.ServerIgnoredCourse]?
        let serverMarkedAssignments: Set<String>
    }

    func markCategoryReenabled(_ category: SyncCategory) {
        app.pushCoordinator.forgetUploads()
        let signIn = app.authService.session.currentSignIn
        Self.markForReenableCheck(category, signedIn: app.authService.hasStoredCredentials, for: signIn)
        useLocalHold.noteReenabled(category)
    }

    static func markForReenableCheck(_ category: SyncCategory, signedIn: Bool, for signIn: SignIn) {
        let synced = hasSynced(category)
        guard signedIn, synced else {
            AppLogger.sync.info("[reenable] not marked: \(category.rawValue, privacy: .public), signedIn=\(signedIn, privacy: .public) synced=\(synced, privacy: .public)")
            return
        }
        SyncProgress.changePendingConflicts(for: signIn) { $0.insert(category) }
        AppLogger.sync.info("[reenable] marked category: \(category.rawValue, privacy: .public), pending=\(Defaults[.pendingConflictCategories].logged, privacy: .public)")
    }

    static func hasSynced(_ category: SyncCategory) -> Bool {
        Defaults[.categoriesSyncedOnce].contains(category)
    }

    static func switchedOnCategories() -> Set<SyncCategory> {
        SyncPolicy.current.switchedOn
    }

    func checkPendingConflicts() {
        let pending = Self.categoriesToCheck(
            pending: Defaults[.pendingConflictCategories], answering: useLocalHold.held
        )
        let signIn = app.authService.session.currentSignIn
        guard !pending.isEmpty, Defaults[.cloudSyncEnabled] else {
            AppLogger.sync.info("[reenable] checkPendingConflicts skip: pending=\(Defaults[.pendingConflictCategories].logged, privacy: .public) syncEnabled=\(Defaults[.cloudSyncEnabled], privacy: .public)")
            return
        }
        guard !isCheckingConflicts else {
            AppLogger.sync.info("[reenable] checkPendingConflicts skipped — already in flight")
            return
        }
        isCheckingConflicts = true
        AppLogger.sync.info("[reenable] checkPendingConflicts start: pending=\(pending.logged, privacy: .public)")
        Task {
            defer {
                Task { @MainActor in self.endConflictCheck(checked: pending, startedIn: signIn) }
            }
            do {
                let (json, courseDeletes) = try await app.cloudSyncCoordinator.courseDeletes(around: {
                    try await app.pushCoordinator.fetchFullSync(for: signIn)
                })
                let found = ReenableDifferences.find(
                    in: json, checking: pending, courseDeletes: courseDeletes,
                    studentId: { app.authService.storedStudentId }
                )
                await MainActor.run {
                    let outcome = Self.conflictCheckOutcome(
                        mayWrite: app.fullSync.mayWrite(for: signIn), checked: pending,
                        stillPending: Self.categoriesToCheck(
                            pending: Defaults[.pendingConflictCategories], answering: useLocalHold.held
                        ),
                        foundDifference: !found.lines.isEmpty
                    )
                    conflictCheckRetry.note(outcome, at: Date(), signIn: signIn)
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
                        SyncProgress.changePendingConflicts(for: signIn) { $0.subtract(checked) }
                        app.cloudSyncCoordinator.scheduleTick()
                    }
                }
            } catch {
                conflictCheckRetry.noteFailure(at: Date(), signIn: signIn)
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

    private func endConflictCheck(checked pending: Set<SyncCategory>, startedIn signIn: SignIn) {
        isCheckingConflicts = false
        let unchecked = Self.categoriesLeftToCheck(
            pending: Defaults[.pendingConflictCategories], checked: pending,
            signedOutSince: !signIn.isCurrent
        )
        if reenableConflict == nil, !unchecked.isEmpty {
            checkPendingConflicts()
        }
    }

    func retryOwedConflictCheck() {
        guard conflictCheckRetry.isDue(
            pending: Defaults[.pendingConflictCategories], checking: isCheckingConflicts,
            awaitingAnswer: reenableConflict != nil, now: Date()
        ) else { return }
        checkPendingConflicts()
    }

    nonisolated struct ConflictCheckRetry: Sendable {
        static let firstDelay: TimeInterval = 30
        static let maxDelay: TimeInterval = 30 * 60

        private struct Attempts: Sendable {
            var owed = true
            var failures = 0
            var notBefore: Date?

            mutating func recordFailure(at now: Date) {
                owed = true
                failures += 1
                notBefore = now.addingTimeInterval(min(ConflictCheckRetry.firstDelay * pow(2, Double(failures - 1)), ConflictCheckRetry.maxDelay))
            }
        }

        private var attempts = SignInBound(empty: Attempts())

        func isDue(pending: Set<SyncCategory>, checking: Bool, awaitingAnswer: Bool, now: Date) -> Bool {
            let state = attempts.value
            return state.owed && !pending.isEmpty && !checking && !awaitingAnswer
                && (state.notBefore.map { now >= $0 } ?? true)
        }

        mutating func noteFailure(at now: Date, signIn: SignIn) {
            change(for: signIn) { $0.recordFailure(at: now) }
        }

        mutating func note(_ outcome: ConflictCheckOutcome, at now: Date, signIn: SignIn) {
            change(for: signIn) { state in
                switch outcome {
                case .dropped:
                    state.recordFailure(at: now)
                case .conflict, .clear:
                    state = Attempts(owed: false)
                case .resolvedMeanwhile:
                    break
                }
            }
        }

        mutating func noteAnswered(
            leaving pending: Set<SyncCategory>, awaitingAnswer: Bool, saveFailed: Bool = false, at now: Date = Date(),
            signIn: SignIn
        ) {
            change(for: signIn) { state in
                if saveFailed { return state.recordFailure(at: now) }
                if !pending.isEmpty, !awaitingAnswer { state.owed = true }
            }
        }

        private mutating func change(for signIn: SignIn, _ body: (inout Attempts) -> Void) {
            var state = attempts.value
            body(&state)
            attempts.set(state, for: signIn)
        }
    }

    nonisolated enum ConflictCheckOutcome: Equatable, Sendable {
        case dropped
        case resolvedMeanwhile
        case conflict(Set<SyncCategory>)
        case clear(Set<SyncCategory>)
    }

    nonisolated static func conflictCheckOutcome(
        mayWrite: Bool, checked: Set<SyncCategory>, stillPending: Set<SyncCategory>, foundDifference: Bool
    ) -> ConflictCheckOutcome {
        guard mayWrite else { return .dropped }
        let stillChecked = checked.intersection(stillPending)
        guard !stillChecked.isEmpty else { return .resolvedMeanwhile }
        return foundDifference ? .conflict(stillChecked) : .clear(stillChecked)
    }

    nonisolated static func categoriesLeftToCheck(
        pending: Set<SyncCategory>, checked: Set<SyncCategory>, signedOutSince: Bool
    ) -> Set<SyncCategory> {
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

    var reenableAlertIsPresented: Binding<Bool> {
        Self.reenableAlertIsPresented(Bindable(self).reenableConflict)
    }

    func resolveReenableConflict(keepLocal: Bool) {
        guard let conflict = reenableConflict else { return }
        AppLogger.sync.info("[reenable] resolve: keepLocal=\(keepLocal, privacy: .public) categories=\(conflict.categories.map(\.rawValue), privacy: .public)")
        reenableConflict = nil
        let signIn = app.authService.session.currentSignIn
        let effects = ReenableAnswerEffects(
            signIn: signIn,
            take: { categories, keepLocal in
                SyncProgress.changePendingConflicts(for: signIn) {
                    self.useLocalHold.take(categories, keepLocal: keepLocal, from: &$0)
                } ?? []
            },
            release: {
                let kept = $0
                SyncProgress.changePendingConflicts(for: signIn) { self.useLocalHold.release(kept, from: &$0) }
                self.app.cloudSyncCoordinator.scheduleTick()
            },
            end: { self.useLocalHold.end($0) },
            dropQueuedEdits: { await self.app.cloudSyncCoordinator.discardEdits(of: $0, courseIgnores: $1) },
            sendCourses: {
                try await ReenableAnswer.sendLocalCourses(
                    localEdits: self.app.localEdits, push: self.app.pushCoordinator,
                    clock: self.app.cloudSyncCoordinator.clock, for: signIn
                )
            },
            markCoursesForCheck: { self.markCategoryReenabled(.courses) },
            queueEdits: { ReenableAnswer.queueLocalEdits(of: conflict, edits: self.app.edits, for: signIn) },
            dropLocalCopies: { Self.dropLocalCopies(for: conflict, signIn: signIn) },
            syncFromServer: { await self.app.fullSync.sync(followUpIfBusy: $0) },
            noteAnswered: { saveFailed in
                self.conflictCheckRetry.noteAnswered(
                    leaving: Defaults[.pendingConflictCategories], awaitingAnswer: self.reenableConflict != nil,
                    saveFailed: saveFailed, signIn: signIn
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

    nonisolated static func categoriesToCheck(pending: Set<SyncCategory>, answering: Set<SyncCategory>) -> Set<SyncCategory> {
        pending.subtracting(answering)
    }

    nonisolated struct UseLocalHold: Equatable, Sendable {
        private(set) var held: Set<SyncCategory> = []
        private var reenabled: Set<SyncCategory> = []

        mutating func take(_ categories: [SyncCategory], keepLocal: Bool, from pending: inout Set<SyncCategory>) -> Set<SyncCategory> {
            guard keepLocal else {
                pending.subtract(categories)
                return []
            }
            held.formUnion(categories)
            return Set(categories)
        }

        mutating func noteReenabled(_ category: SyncCategory) {
            if held.contains(category) { reenabled.insert(category) }
        }

        mutating func release(_ kept: Set<SyncCategory>, from pending: inout Set<SyncCategory>) {
            pending.subtract(kept.subtracting(reenabled))
            end(kept)
        }

        mutating func end(_ kept: Set<SyncCategory>) {
            held.subtract(kept)
            reenabled.subtract(kept)
        }
    }

    static func dropLocalCopies(
        for conflict: ReenableConflict, courses: CourseStore = .shared, assignments: AssignmentStore = .shared,
        colors: CourseColorStore = .shared, signIn: SignIn
    ) {
        ReenableAnswer.dropLocalCopies(
            for: conflict, courses: courses, assignments: assignments, colors: colors, signIn: signIn
        )
    }

    static func keepLocalCourses(
        _ terms: [(semester: String, fetched: [SDCourse], userAdded: [SDCourse])], hiding deletedNos: Set<String>,
        on backend: some CourseSyncBackend, for signIn: SignIn
    ) async throws {
        try await ReenableAnswer.keepLocalCourses(terms, hiding: deletedNos, on: backend, for: signIn)
    }
}

protocol CourseSyncBackend {
    func deleteAllCourses(semester: String?, madeAt: Date, for signIn: SignIn) async throws
    func uploadCourses(_ request: PushAPI.CourseUploadRequest, addedAt: Date?, for signIn: SignIn) async throws
    func deleteCourse(courseKey: String, kind: PushAPI.CourseDeleteKind?, madeAt: Date, for signIn: SignIn) async throws
}

extension PushCoordinator: CourseSyncBackend {}
