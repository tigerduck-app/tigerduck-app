import Defaults
import Foundation

private final class AssignmentRound {
    let signIn: AccountSession.Ticket
    let rechecks: Bool
    var task: Task<Void, Never>?
    var assignments: [SDAssignment] = []

    init(signIn: AccountSession.Ticket, rechecks: Bool) {
        self.signIn = signIn
        self.rechecks = rechecks
    }
}

final class AssignmentRounds {
    static let shared = AssignmentRounds()

    fileprivate var running: AssignmentRound?
    fileprivate var statusAskedAt: [String: ContinuousClock.Instant] = [:]
}

/// Moodle assignment rounds: one at a time for every caller, saved and uploaded for reminders.
enum AssignmentFetch {

    static var assignmentUploader: ((PushAPI.AssignmentUploadRequest) -> Void)?

    static func fetchAssignments(authService: AuthService, recheckSubmissions: Bool = false) async -> [SDAssignment] {
        let ticket = authService.session.ticket
        return await sharedRound(
            signIn: ticket,
            rechecks: recheckSubmissions,
            isCurrent: { authService.session.isCurrent(ticket) }
        ) {
            await runAssignmentRound(authService: authService, recheckSubmissions: recheckSubmissions)
        }
    }

    static func sharedRound(
        signIn: AccountSession.Ticket,
        rechecks: Bool,
        isCurrent: @MainActor () -> Bool,
        rounds: AssignmentRounds = .shared,
        run: @escaping @MainActor () async -> [SDAssignment]
    ) async -> [SDAssignment] {
        var waitedFor: AssignmentRound?
        while let round = rounds.running, round.signIn == signIn, round !== waitedFor {
            await round.task?.value
            if round.rechecks || !rechecks { return answer(round, isCurrent: isCurrent) }
            waitedFor = round
        }
        guard isCurrent() else { return AssignmentStore.shared.loadAssignments() }
        let round = AssignmentRound(signIn: signIn, rechecks: rechecks)
        round.task = Task { round.assignments = await run() }
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

    static func refreshAssignmentsIfDue(authService: AuthService) async {
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
        _ = await fetchAssignments(authService: authService)
        if showsProgress, manager.loadingStarts == starts { manager.loadingState = .loaded }
    }

    static func cancelAssignmentRound() {
        AssignmentRounds.shared.running?.task?.cancel()
        AssignmentRounds.shared.running = nil
    }

    private static func runAssignmentRound(authService: AuthService, recheckSubmissions: Bool) async -> [SDAssignment] {
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
            let answers = await askStatuses(of: recordsToAsk) {
                try await MoodleAssignmentService.fetchSubmissionStatus(assignId: $0)
            }
            let statuses = answers.mapValues(\.status)

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

            let persisted = persistRound(
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
                uploadForReminders(assignmentsToPersist)
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

    static func persistRound(
        _ assignments: [SDAssignment],
        records: [MoodleAssignmentRecord],
        closed: [String: Date],
        answered: [Int: ContinuousClock.Instant],
        account: String,
        fetchedAt: Date,
        assignments store: AssignmentStore,
        moodle: MoodleFiles,
        rounds: AssignmentRounds = .shared,
        isCurrent: () -> Bool
    ) -> Bool {
        guard !Task.isCancelled, isCurrent() else { return false }
        store.saveAssignments(assignments)
        moodle.saveMoodleData(records, fetchedAt: fetchedAt, name: MoodleAssignmentRecord.cacheName, account: account)
        store.replaceClosedUnsubmittedAssignments(closed)
        saveMoodleCalendarEvents(of: assignments, in: store)
        for (id, askedAt) in answered { rounds.statusAskedAt[String(id)] = askedAt }
        return true
    }

    private static func saveMoodleCalendarEvents(of assignments: [SDAssignment], in cache: AssignmentStore) {
        var calendarEvents = cache.loadCalendarEvents()
        calendarEvents.removeAll { $0.source == .moodle }
        calendarEvents.append(contentsOf: assignments.map(AssignmentRecords.moodleCalendarEvent))
        cache.saveCalendarEvents(calendarEvents)
    }

    static func askStatuses(
        of records: [MoodleAssignmentRecord],
        limit: Int = maxConcurrentRequests,
        fetch: @escaping @Sendable (_ assignId: Int) async throws -> MoodleSubmissionStatus
    ) async -> [Int: (status: MoodleSubmissionStatus, askedAt: ContinuousClock.Instant)] {
        typealias Answer = (Int, MoodleSubmissionStatus, ContinuousClock.Instant)
        let answers = await concurrentMap(records, limit: limit) { record -> Answer? in
            let askedAt = ContinuousClock.now
            guard let status = try? await fetch(record.assignId) else { return nil }
            return (record.assignId, status, askedAt)
        }
        return Dictionary(
            answers.compactMap { $0.map { ($0.0, (status: $0.1, askedAt: $0.2)) } },
            uniquingKeysWith: { first, _ in first }
        )
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
        if assignment.dueDate != dueBefore { saveMoodleCalendarEvents(of: assignments, in: cache) }
        // An extension ahead takes submissions past the cutoff, so rounds ask about it again.
        if let extended = status.extensionDueDate, extended > Date() {
            var closed = cache.loadClosedUnsubmittedAssignments()
            if closed.removeValue(forKey: id) != nil { cache.replaceClosedUnsubmittedAssignments(closed) }
        }
        uploadForReminders(assignments)
        return true
    }

    private static func uploadForReminders(_ assignments: [SDAssignment]) {
        #if os(iOS)
        guard let upload = assignmentUploader, Defaults[.cloudSyncEnabled] else { return }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let entries = assignments.compactMap { a -> PushAPI.AssignmentUploadEntry? in
            guard let id = Int(a.assignmentId) else { return nil }
            return PushAPI.AssignmentUploadEntry(
                moodleAssignmentId: id,
                courseNo: a.courseNo,
                courseName: a.courseName,
                title: a.title,
                dueAt: iso.string(from: a.dueDate),
                moodleUrl: a.moodleUrl,
                isSubmitted: a.isCompleted,
                grade: nil
            )
        }
        upload(PushAPI.AssignmentUploadRequest(assignments: entries))
        #endif
    }
}
