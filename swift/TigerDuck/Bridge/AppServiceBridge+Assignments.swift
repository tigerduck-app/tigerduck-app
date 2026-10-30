import Defaults
import Foundation

private final class AssignmentRound {
    let generation: Int
    let rechecks: Bool
    var task: Task<Void, Never>?
    var assignments: [SDAssignment] = []

    init(generation: Int, rechecks: Bool) {
        self.generation = generation
        self.rechecks = rechecks
    }
}

final class AssignmentRounds {
    static let shared = AssignmentRounds()

    fileprivate var running: AssignmentRound?
    fileprivate var statusAskedAt: [String: ContinuousClock.Instant] = [:]
}

extension AppServiceBridge {

    static func fetchAssignments(authService: AuthService, recheckSubmissions: Bool = false) async -> [SDAssignment] {
        let generation = authService.loginGeneration
        return await sharedRound(
            generation: generation,
            rechecks: recheckSubmissions,
            isCurrent: { authService.loginGeneration == generation }
        ) {
            await runAssignmentRound(authService: authService, recheckSubmissions: recheckSubmissions)
        }
    }

    static func sharedRound(
        generation: Int,
        rechecks: Bool,
        isCurrent: @MainActor () -> Bool,
        rounds: AssignmentRounds = .shared,
        run: @escaping @MainActor () async -> [SDAssignment]
    ) async -> [SDAssignment] {
        var waitedFor: AssignmentRound?
        while let round = rounds.running, round.generation == generation, round !== waitedFor {
            await round.task?.value
            if round.rechecks || !rechecks { return answer(round, isCurrent: isCurrent) }
            waitedFor = round
        }
        guard isCurrent() else { return DataCache.shared.loadAssignments() }
        let round = AssignmentRound(generation: generation, rechecks: rechecks)
        round.task = Task { round.assignments = await run() }
        rounds.running = round
        await round.task?.value
        if rounds.running === round { rounds.running = nil }
        return answer(round, isCurrent: isCurrent)
    }

    private static func answer(_ round: AssignmentRound, isCurrent: @MainActor () -> Bool) -> [SDAssignment] {
        isCurrent() ? round.assignments : DataCache.shared.loadAssignments()
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
        NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
    }

    static func cancelAssignmentRound() {
        AssignmentRounds.shared.running?.task?.cancel()
        AssignmentRounds.shared.running = nil
    }

    static func moodleCalendarEvent(_ assignment: SDAssignment) -> SDCalendarEvent {
        SDCalendarEvent(
            eventId: "moodle-\(assignment.assignmentId)",
            title: assignment.displayTitle,
            date: assignment.dueDate,
            source: .moodle
        )
    }

    private static func runAssignmentRound(authService: AuthService, recheckSubmissions: Bool) async -> [SDAssignment] {
        let startGeneration = authService.loginGeneration
        guard let account = authService.storedStudentId,
              authService.storedPassword != nil else {
            return DataCache.shared.loadAssignments()
        }

        do {
            #if DEBUG
            try await ServerFailureSimulator.shared.check(.moodle)
            #endif
            let currentSemester = CourseSelectionService.currentSemesterCode()
            let currentCourses = DataCache.shared.loadCourses(semester: currentSemester)

            let moodleEnrolled = try await MoodleEnrolledCoursesService.fetchEnrolled()
            let moodleIdMapForAssignments = moodleCourseIdMap(moodleEnrolled)
            if !Task.isCancelled,
               authService.loginGeneration == startGeneration {
                DataCache.shared.saveMoodleCourseIdMap(moodleIdMapForAssignments)
            }

            let localCourseNos = Set(currentCourses.map(\.courseNo)).union(
                DataCache.shared.loadUserAddedCourses(semester: currentSemester).map(\.courseNo)
            )
            var currentCourseNos = Set(currentCourses.map(\.courseNo))
            for mc in moodleEnrolled where mc.semester == currentSemester && !mc.courseNo.isEmpty {
                currentCourseNos.insert(mc.courseNo)
            }
            let relevantCourses: [MoodleEnrolledCourse]
            if currentCourseNos.isEmpty {
                relevantCourses = moodleEnrolled.filter { $0.semester == currentSemester }
            } else {
                relevantCourses = coursesForTerm(
                    moodleEnrolled.filter { currentCourseNos.contains($0.courseNo) },
                    semester: currentSemester
                )
            }
            let relevantMoodleCourseIds = relevantCourses.map(\.id)
            guard !relevantMoodleCourseIds.isEmpty else {
                if !moodleEnrolled.isEmpty, authService.loginGeneration == startGeneration {
                    Defaults[.schoolDataSyncedAt] = Date()
                }
                return DataCache.shared.loadAssignments()
            }

            let records = try await MoodleAssignmentService.fetchAssignments(
                courseIds: relevantMoodleCourseIds
            )
            let moodleCoursesById = Dictionary(
                uniqueKeysWithValues: relevantCourses.map { ($0.id, $0) }
            )
            let courseNoByMoodleId = Dictionary(
                uniqueKeysWithValues: relevantCourses.map {
                    ($0.id, assignmentCourseNo(for: $0, localCourseNos: localCourseNos))
                }
            )

            let cachedAssignments = DataCache.shared.loadAssignments()
            let confirmed = recheckSubmissions ? [:] : confirmedSubmissions(in: cachedAssignments)
            let closed = DataCache.shared.loadClosedUnsubmittedAssignments()
            let recordsToAsk = recordsToAskAbout(
                records, confirmed: confirmed, closed: recheckSubmissions ? [:] : closed
            )
            let askedAt = Date()
            let answers = await askStatuses(of: recordsToAsk) {
                try await MoodleAssignmentService.fetchSubmissionStatus(assignId: $0)
            }
            let statuses = answers.mapValues(\.status)

            let freshAssignments = assignments(
                from: records,
                moodleCoursesById: moodleCoursesById,
                courseNoByMoodleId: courseNoByMoodleId,
                statuses: statuses,
                confirmed: confirmed,
                extensions: Dictionary(
                    cachedAssignments.compactMap { a in a.extensionDueDate.map { (a.assignmentId, $0) } },
                    uniquingKeysWith: { first, _ in first }
                ),
                marks: DataCache.shared.assignmentMarks(semester: currentSemester)
            )

            let assignmentsToPersist: [SDAssignment]
            if statuses.count < recordsToAsk.count {
                assignmentsToPersist = preserveCompletionState(
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
                closed: closedUnsubmitted(records: records, statuses: statuses, askedAt: askedAt, kept: closed),
                answered: answers.mapValues(\.askedAt),
                account: account,
                fetchedAt: askedAt,
                cache: .shared,
                isCurrent: { authService.loginGeneration == startGeneration }
            )
            if persisted {
                if statuses.count == recordsToAsk.count {
                    Defaults[.schoolDataSyncedAt] = Date()
                }
                uploadForReminders(assignmentsToPersist)
            }
            await MainActor.run { record(.ok, for: .moodle, round: startGeneration, authService: authService) }
            return assignmentsToPersist
        } catch {
            await MainActor.run {
                let note = (error as? MoodleWebserviceError) == .siteMaintenance ? error.localizedDescription : nil
                record(.failed, for: .moodle, note: note, round: startGeneration, authService: authService)
                AppLogger.captureError(error, context: ["bridge": "fetchAssignments"])
            }
            return DataCache.shared.loadAssignments()
        }
    }

    static func persistRound(
        _ assignments: [SDAssignment],
        records: [MoodleAssignmentRecord],
        closed: [String: Date],
        answered: [Int: ContinuousClock.Instant],
        account: String,
        fetchedAt: Date,
        cache: DataCache,
        rounds: AssignmentRounds = .shared,
        isCurrent: () -> Bool
    ) -> Bool {
        guard !Task.isCancelled, isCurrent() else { return false }
        cache.saveAssignments(assignments)
        cache.saveMoodleData(records, fetchedAt: fetchedAt, name: MoodleAssignmentRecord.cacheName, account: account)
        cache.replaceClosedUnsubmittedAssignments(closed)
        saveMoodleCalendarEvents(of: assignments, in: cache)
        for (id, askedAt) in answered { rounds.statusAskedAt[String(id)] = askedAt }
        return true
    }

    private static func saveMoodleCalendarEvents(of assignments: [SDAssignment], in cache: DataCache) {
        var calendarEvents = cache.loadCalendarEvents()
        calendarEvents.removeAll { $0.source == .moodle }
        calendarEvents.append(contentsOf: assignments.map(moodleCalendarEvent))
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
        cache: DataCache,
        rounds: AssignmentRounds = .shared,
        isCurrent: () -> Bool,
        notifying center: NotificationCenter = .default
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
        center.post(name: AppConstants.dataDidUpdate, object: nil)
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

    static func assignments(
        from records: [MoodleAssignmentRecord],
        moodleCoursesById: [Int: MoodleEnrolledCourse],
        courseNoByMoodleId: [Int: String],
        statuses: [Int: MoodleSubmissionStatus],
        confirmed: [String: Date],
        extensions: [String: Date] = [:],
        marks: AssignmentMarks
    ) -> [SDAssignment] {
        records.compactMap { record in
            let status = statuses[record.assignId]
            let assignmentId = String(record.assignId)
            let extensionDate = status == nil ? extensions[assignmentId] : status?.extensionDueDate
            guard let dueDate = record.dueDate else { return nil }
            guard !record.noSubmissions else { return nil }

            let moodleCourse = moodleCoursesById[record.courseId]
            let confirmedAt = confirmed[assignmentId]
            return marks.apply(to: SDAssignment(
                assignmentId: assignmentId,
                courseNo: moodleCourse.flatMap { courseNoByMoodleId[$0.id] } ?? "",
                courseName: moodleCourse.map { courseName(from: $0.fullname) } ?? "",
                title: record.name,
                dueDate: dueDate,
                isCompleted: status?.isSubmitted ?? (confirmedAt != nil),
                moodleUrl: "\(AppConstants.moodleBaseURL.absoluteString)/mod/assign/view.php?id=\(record.cmId)",
                cutoffDate: record.cutoffDate,
                submittedAt: status?.submittedAt ?? confirmedAt,
                extensionDueDate: extensionDate,
                semester: marks.semester
            ))
        }
    }

    static func recordsToAskAbout(
        _ records: [MoodleAssignmentRecord],
        confirmed: [String: Date],
        closed: [String: Date]
    ) -> [MoodleAssignmentRecord] {
        records.filter { record in
            let id = String(record.assignId)
            return record.dueDate != nil && !record.noSubmissions && confirmed[id] == nil
                && !isClosed(record, askedAt: closed[id])
        }
    }

    /// id. It takes no submission after the cutoff, so a round need not ask again until a teacher
    /// moves the cutoff past that answer. `askedAt` precedes the round's requests, and one left
    static func closedUnsubmitted(
        records: [MoodleAssignmentRecord],
        statuses: [Int: MoodleSubmissionStatus],
        askedAt: Date,
        kept: [String: Date]
    ) -> [String: Date] {
        var closed: [String: Date] = [:]
        for record in records {
            let id = String(record.assignId)
            if let status = statuses[record.assignId] {
                // An extension takes this student's submission past the cutoff.
                if !status.isSubmitted, isClosed(record, askedAt: askedAt),
                   (status.extensionDueDate ?? .distantPast) < askedAt { closed[id] = askedAt }
            } else if let keptAt = kept[id], isClosed(record, askedAt: keptAt) {
                closed[id] = keptAt
            }
        }
        return closed
    }

    private static func isClosed(_ record: MoodleAssignmentRecord, askedAt: Date?) -> Bool {
        guard let askedAt, let cutoff = record.cutoffDate else { return false }
        return cutoff < askedAt
    }

    /// One Moodle course per course number. Moodle keeps past enrolments, so a retaken course
    /// has one for each term it was taken in; this term's wins, else the one that started last.
    static func coursesForTerm(_ courses: [MoodleEnrolledCourse], semester: String) -> [MoodleEnrolledCourse] {
        let byCourseNo = Dictionary(grouping: courses, by: \.courseNo)
        return courses.filter { course in
            guard let siblings = byCourseNo[course.courseNo], siblings.count > 1 else { return true }
            if siblings.contains(where: { $0.semester == semester }) { return course.semester == semester }
            let latest = siblings.max { ($0.startDate ?? .distantPast, $0.id) < ($1.startDate ?? .distantPast, $1.id) }
            return course.id == latest?.id
        }
    }

    /// Submissions Moodle has confirmed, with their time, by assignment id. Moodle keeps a
    /// submission once it has a time, short of a teacher reverting it to a draft.
    static func confirmedSubmissions(in cached: [SDAssignment]) -> [String: Date] {
        Dictionary(
            cached.compactMap { assignment in
                guard assignment.isCompleted, let submittedAt = assignment.submittedAt else { return nil }
                return (assignment.assignmentId, submittedAt)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    static func preserveCompletionState(
        freshAssignments: [SDAssignment],
        cachedAssignments: [SDAssignment],
        answeredIds: Set<String>
    ) -> [SDAssignment] {
        let previousById = Dictionary(
            uniqueKeysWithValues: cachedAssignments.map { ($0.assignmentId, $0) }
        )

        for assignment in freshAssignments where !answeredIds.contains(assignment.assignmentId) {
            guard let previous = previousById[assignment.assignmentId],
                  previous.isCompleted else { continue }
            assignment.isCompleted = true
            if assignment.submittedAt == nil {
                assignment.submittedAt = previous.submittedAt
            }
        }

        return freshAssignments
    }

    private static func courseName(from fullname: String) -> String {
        let parts = fullname.components(separatedBy: " ")
        guard parts.count >= 2 else { return fullname }

        if let index = parts.firstIndex(where: { CourseSelectionService.isCourseNo($0[...]) }), index + 1 < parts.count {
            return parts[(index + 1)...].joined(separator: " ")
        }

        return fullname
    }
}
