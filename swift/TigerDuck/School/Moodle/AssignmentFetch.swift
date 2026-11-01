import Defaults
import Foundation

typealias PullGate = @MainActor () async -> Bool

private final class AssignmentRound {
    let signIn: AccountSession.Ticket
    let rechecks: Bool
    var task: Task<Void, Never>?
    var assignments: [SDAssignment] = []
    var gates: [PullGate] = []

    init(signIn: AccountSession.Ticket, rechecks: Bool) {
        self.signIn = signIn
        self.rechecks = rechecks
    }

    func pulled() async -> Bool {
        var next = 0
        while next < gates.count {
            if await gates[next]() { return true }
            next += 1
        }
        return false
    }
}

final class AssignmentRounds {
    static let shared = AssignmentRounds()

    fileprivate var running: AssignmentRound?
    var statusAskedAt: [String: ContinuousClock.Instant] = [:]
}

enum AssignmentFetch {

    static func fetchAssignments(
        authService: AuthService, recheckSubmissions: Bool = false,
        applyAfter: @escaping PullGate = { true }
    ) async -> [SDAssignment] {
        let ticket = authService.session.ticket
        return await sharedRound(
            signIn: ticket,
            rechecks: recheckSubmissions,
            isCurrent: { authService.session.isCurrent(ticket) },
            applyAfter: applyAfter
        ) { pulled in
            await runAssignmentRound(
                authService: authService, recheckSubmissions: recheckSubmissions, applyAfter: pulled
            )
        }
    }

    static func sharedRound(
        signIn: AccountSession.Ticket,
        rechecks: Bool,
        isCurrent: @MainActor () -> Bool,
        rounds: AssignmentRounds = .shared,
        applyAfter: @escaping PullGate = { true },
        run: @escaping @MainActor (_ pulled: @escaping PullGate) async -> [SDAssignment]
    ) async -> [SDAssignment] {
        var waitedFor: AssignmentRound?
        while let round = rounds.running, round.signIn == signIn, round !== waitedFor {
            round.gates.append(applyAfter)
            await round.task?.value
            if round.rechecks || !rechecks { return answer(round, isCurrent: isCurrent) }
            waitedFor = round
        }
        guard isCurrent() else { return AssignmentStore.shared.loadAssignments() }
        let round = AssignmentRound(signIn: signIn, rechecks: rechecks)
        round.gates = [applyAfter]
        round.task = Task { round.assignments = await run { await round.pulled() } }
        rounds.running = round
        await round.task?.value
        if rounds.running === round { rounds.running = nil }
        return answer(round, isCurrent: isCurrent)
    }

    private static func answer(_ round: AssignmentRound, isCurrent: @MainActor () -> Bool) -> [SDAssignment] {
        isCurrent() ? round.assignments : AssignmentStore.shared.loadAssignments()
    }

    static let foregroundRefreshInterval: TimeInterval = 60

    private static var lastForegroundAttempt: Date?

    static func isForegroundRefreshDue(syncedAt: Date?, lastAttempt: Date?, now: Date) -> Bool {
        [syncedAt, lastAttempt].allSatisfy { date in
            guard let date else { return true }
            let age = now.timeIntervalSince(date)
            return age >= foregroundRefreshInterval || age < 0
        }
    }

    static func refreshAssignmentsIfDue(
        authService: AuthService, applyAfter: @escaping PullGate = { true }
    ) async {
        let now = Date()
        guard authService.storedStudentId != nil,
              isForegroundRefreshDue(
                syncedAt: Defaults[.schoolDataSyncedAt], lastAttempt: lastForegroundAttempt, now: now
              ),
              await NetworkMonitor.shared.isReachable() else { return }
        lastForegroundAttempt = now
        let manager = NTUSTSessionManager.shared
        let showsProgress = manager.loadingState == .idle || manager.loadingState == .loaded
        if showsProgress { manager.loadingState = .loading }
        let starts = manager.loadingStarts
        _ = await fetchAssignments(authService: authService, applyAfter: applyAfter)
        if showsProgress, manager.loadingStarts == starts { manager.loadingState = .loaded }
    }

    static func cancelAssignmentRound() {
        AssignmentRounds.shared.running?.task?.cancel()
        AssignmentRounds.shared.running = nil
    }

    private static func runAssignmentRound(
        authService: AuthService, recheckSubmissions: Bool, applyAfter: PullGate
    ) async -> [SDAssignment] {
        let ticket = authService.session.ticket
        guard let account = authService.storedStudentId,
              authService.storedPassword != nil else {
            return AssignmentStore.shared.loadAssignments()
        }

        do {
            #if DEBUG
            try await ServerFailureSimulator.shared.check(.moodle)
            #endif
            let currentSemester = CourseSelectionService.currentSemesterCode()
            let currentCourses = CourseStore.shared.loadCourses(semester: currentSemester)

            let moodleEnrolled = try await MoodleEnrolledCoursesService.fetchEnrolled()
            let moodleIdMapForAssignments = AssignmentRecords.moodleCourseIdMap(moodleEnrolled)
            if !Task.isCancelled,
               authService.session.isCurrent(ticket) {
                MoodleFiles.shared.saveMoodleCourseIdMap(moodleIdMapForAssignments)
            }

            let localCourseNos = Set(currentCourses.map(\.courseNo)).union(
                CourseStore.shared.loadUserAddedCourses(semester: currentSemester).map(\.courseNo)
            )
            var currentCourseNos = Set(currentCourses.map(\.courseNo))
            for mc in moodleEnrolled where mc.semester == currentSemester && !mc.courseNo.isEmpty {
                currentCourseNos.insert(mc.courseNo)
            }
            let relevantCourses: [MoodleEnrolledCourse]
            if currentCourseNos.isEmpty {
                relevantCourses = moodleEnrolled.filter { $0.semester == currentSemester }
            } else {
                relevantCourses = AssignmentRecords.coursesForTerm(
                    moodleEnrolled.filter { currentCourseNos.contains($0.courseNo) },
                    semester: currentSemester
                )
            }
            let relevantMoodleCourseIds = relevantCourses.map(\.id)
            guard !relevantMoodleCourseIds.isEmpty else {
                if !moodleEnrolled.isEmpty, authService.session.isCurrent(ticket) {
                    Defaults[.schoolDataSyncedAt] = Date()
                }
                return AssignmentStore.shared.loadAssignments()
            }

            let records = try await MoodleAssignmentService.fetchAssignments(
                courseIds: relevantMoodleCourseIds
            )
            let moodleCoursesById = Dictionary(
                uniqueKeysWithValues: relevantCourses.map { ($0.id, $0) }
            )
            let courseNoByMoodleId = Dictionary(
                uniqueKeysWithValues: relevantCourses.map {
                    ($0.id, AssignmentRecords.assignmentCourseNo(for: $0, localCourseNos: localCourseNos))
                }
            )

            let cachedAssignments = AssignmentStore.shared.loadAssignments()
            let confirmed = recheckSubmissions ? [:] : AssignmentRecords.confirmedSubmissions(in: cachedAssignments)
            let closed = AssignmentStore.shared.loadClosedUnsubmittedAssignments()
            let recordsToAsk = AssignmentRecords.recordsToAskAbout(
                records, confirmed: confirmed, closed: recheckSubmissions ? [:] : closed
            )
            let askedAt = Date()
            let answers = await AssignmentAnswers.askStatuses(of: recordsToAsk) {
                try await MoodleAssignmentService.fetchSubmissionStatus(assignId: $0)
            }
            let statuses = answers.mapValues(\.status)
            guard await applyAfter() else { return AssignmentStore.shared.loadAssignments() }

            let freshAssignments = AssignmentRecords.assignments(
                from: records,
                moodleCoursesById: moodleCoursesById,
                courseNoByMoodleId: courseNoByMoodleId,
                statuses: statuses,
                confirmed: confirmed,
                extensions: Dictionary(
                    cachedAssignments.compactMap { a in a.extensionDueDate.map { (a.assignmentId, $0) } },
                    uniquingKeysWith: { first, _ in first }
                ),
                marks: AssignmentStore.shared.assignmentMarks(semester: currentSemester)
            )

            let assignmentsToPersist: [SDAssignment]
            if statuses.count < recordsToAsk.count {
                assignmentsToPersist = AssignmentRecords.preserveCompletionState(
                    freshAssignments: freshAssignments,
                    cachedAssignments: cachedAssignments,
                    answeredIds: Set(statuses.keys.map(String.init))
                )
            } else {
                assignmentsToPersist = freshAssignments
            }

            let persisted = AssignmentAnswers.persistRound(
                assignmentsToPersist,
                records: records,
                closed: AssignmentRecords.closedUnsubmitted(records: records, statuses: statuses, askedAt: askedAt, kept: closed),
                answered: answers.mapValues(\.askedAt),
                account: account,
                fetchedAt: askedAt,
                assignments: .shared,
                moodle: .shared,
                isCurrent: { authService.session.isCurrent(ticket) }
            )
            if persisted {
                if statuses.count == recordsToAsk.count {
                    Defaults[.schoolDataSyncedAt] = Date()
                }
                AssignmentAnswers.uploadForReminders(assignmentsToPersist)
            }
            await MainActor.run { CourseFetch.record(.ok, for: .moodle, round: ticket, authService: authService) }
            return assignmentsToPersist
        } catch {
            await MainActor.run {
                let note = (error as? MoodleWebserviceError) == .siteMaintenance ? error.localizedDescription : nil
                CourseFetch.record(.failed, for: .moodle, note: note, round: ticket, authService: authService)
                AppLogger.captureError(error, context: ["bridge": "fetchAssignments"])
            }
            return AssignmentStore.shared.loadAssignments()
        }
    }

    @discardableResult
    static func takeSubmissionStatus(
        _ status: MoodleSubmissionStatus,
        askedAt: ContinuousClock.Instant,
        assignments cache: AssignmentStore,
        rounds: AssignmentRounds = .shared,
        isCurrent: () -> Bool
    ) async -> Bool {
        var waitedFor: AssignmentRound?
        while let round = rounds.running, round !== waitedFor {
            await round.task?.value
            waitedFor = round
        }
        let id = String(status.assignId)
        guard !Task.isCancelled, isCurrent(), rounds.statusAskedAt[id].map({ $0 < askedAt }) ?? true else { return false }
        rounds.statusAskedAt[id] = askedAt
        let assignments = cache.loadAssignments()
        guard let assignment = assignments.first(where: { $0.assignmentId == id }) else { return false }
        let dueBefore = assignment.dueDate
        let extensionBefore = assignment.extensionDueDate
        assignment.extend(to: status.extensionDueDate)
        guard assignment.isCompleted != status.isSubmitted || assignment.submittedAt != status.submittedAt
            || assignment.dueDate != dueBefore || assignment.extensionDueDate != extensionBefore else { return false }
        assignment.isCompleted = status.isSubmitted
        assignment.submittedAt = status.submittedAt
        cache.saveAssignments(assignments)
        if assignment.dueDate != dueBefore { AssignmentAnswers.saveMoodleCalendarEvents(of: assignments, in: cache) }
        // An extension ahead takes submissions past the cutoff, so rounds ask about it again.
        if let extended = status.extensionDueDate, extended > Date() {
            var closed = cache.loadClosedUnsubmittedAssignments()
            if closed.removeValue(forKey: id) != nil { cache.replaceClosedUnsubmittedAssignments(closed) }
        }
        AssignmentAnswers.uploadForReminders(assignments)
        return true
    }
}
