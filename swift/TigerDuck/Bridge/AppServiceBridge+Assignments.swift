import Defaults
import Foundation

/// The result stays on the main actor, so a waiter reads it after the round's `Void` task ends
/// instead of taking the non-Sendable models out of the task.
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

extension AppServiceBridge {

    private static var runningRound: AssignmentRound?

    /// One Moodle assignment round at a time: launch, a return to the app and the Home, Class
    /// Table and Calendar pulls write the same cache. A caller joins the round in flight for its
    /// account, unless it wants submissions rechecked and that round does not.
    ///
    /// `recheckSubmissions` asks Moodle about every submission. Without it a round skips the
    /// ones ``recordsToAskAbout(_:confirmed:closed:)`` leaves out, so a pull, or Refresh on the
    /// Mac, is what shows a reverted submission.
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
        isCurrent: @escaping @MainActor () -> Bool,
        run: @escaping @MainActor () async -> [SDAssignment]
    ) async -> [SDAssignment] {
        // A round that finished stays in `runningRound` until its starter resumes; the
        // identity check keeps a waiter from taking that finished round for a new one.
        var waitedFor: AssignmentRound?
        while let round = runningRound, round.generation == generation, round !== waitedFor {
            await round.task?.value
            if round.rechecks || !rechecks { return answer(round, isCurrent: isCurrent) }
            waitedFor = round
        }
        let round = AssignmentRound(generation: generation, rechecks: rechecks)
        round.task = Task { round.assignments = await run() }
        runningRound = round
        await round.task?.value
        if runningRound === round { runningRound = nil }
        return answer(round, isCurrent: isCurrent)
    }

    /// A round the account signed out of while Moodle answered built the departing account's
    /// list, which the next account's screens would show; the cache the sign-out emptied is theirs.
    private static func answer(_ round: AssignmentRound, isCurrent: @MainActor () -> Bool) -> [SDAssignment] {
        isCurrent() ? round.assignments : DataCache.shared.loadAssignments()
    }

    /// A return to the app refreshes Moodle assignments once the school data is this old.
    static let foregroundRefreshInterval: TimeInterval = 60

    private static var lastForegroundAttempt: Date?

    /// Due once neither the last answered round nor the last attempt is that recent, so a
    /// Moodle that keeps failing is not asked on every return. A date ahead of the clock, left
    /// by a clock set back, counts as old.
    static func isForegroundRefreshDue(syncedAt: Date?, lastAttempt: Date?, now: Date) -> Bool {
        [syncedAt, lastAttempt].allSatisfy { date in
            guard let date else { return true }
            let age = now.timeIntervalSince(date)
            return age >= foregroundRefreshInterval || age < 0
        }
    }

    /// Runs on every return to the foreground. Offline it does nothing, so the indicator does
    /// not spin and Moodle is not marked failed.
    static func refreshAssignmentsIfDue(authService: AuthService) async {
        let now = Date()
        guard authService.storedStudentId != nil,
              isForegroundRefreshDue(
                syncedAt: Defaults[.schoolDataSyncedAt], lastAttempt: lastForegroundAttempt, now: now
              ),
              await NetworkMonitor.shared.isReachable() else { return }
        lastForegroundAttempt = now
        // A sync that shows progress or an error owns the indicator, and so does one that starts
        // during this round, so this round ends it only when no other sync started meanwhile.
        let manager = NTUSTSessionManager.shared
        let showsProgress = manager.loadingState == .idle || manager.loadingState == .loaded
        if showsProgress { manager.loadingState = .loading }
        let starts = manager.loadingStarts
        _ = await fetchAssignments(authService: authService)
        if showsProgress, manager.loadingStarts == starts { manager.loadingState = .loaded }
        NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
    }

    /// Sign-out stops the departing account's round; its writes would be skipped anyway.
    static func cancelAssignmentRound() {
        runningRound?.task?.cancel()
        runningRound = nil
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
        guard authService.storedStudentId != nil,
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
            // `fetchCourses` saves this map too, but assignments can finish first on a
            // cold launch, and the deep-link button should not wait. Replaced whole as in
            // `fetchCourses`, with the same guard against a mid-fetch logout.
            let moodleIdMapForAssignments = moodleCourseIdMap(moodleEnrolled)
            if !Task.isCancelled,
               authService.loginGeneration == startGeneration {
                DataCache.shared.saveMoodleCourseIdMap(moodleIdMapForAssignments)
            }

            // The course cache is empty on first launch (courses sync in parallel); rather
            // than blank Assignments, filter by roster (handles drops), else Moodle's term.
            // `localCourseNos` skips the Moodle widening; it picks a co-listed course's code.
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
                // Moodle answered: nothing for this term yet. An answer with no courses at
                // all says nothing about the term, so it leaves the data undated.
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
            // Resolved once per course rather than once per assignment: the
            // scan over `courseNos` runs a regex across the course fullname.
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
            let answers = await concurrentMap(recordsToAsk) { record -> (Int, MoodleSubmissionStatus)? in
                guard let status = try? await MoodleAssignmentService.fetchSubmissionStatus(
                    assignId: record.assignId
                ) else {
                    return nil
                }
                return (record.assignId, status)
            }
            let statuses = Dictionary(answers.compactMap { $0 }, uniquingKeysWith: { first, _ in first })

            let freshAssignments = assignments(
                from: records,
                moodleCoursesById: moodleCoursesById,
                courseNoByMoodleId: courseNoByMoodleId,
                statuses: statuses,
                confirmed: confirmed,
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

            if !Task.isCancelled,
               authService.loginGeneration == startGeneration {
                DataCache.shared.saveAssignments(assignmentsToPersist)
                DataCache.shared.replaceClosedUnsubmittedAssignments(closedUnsubmitted(
                    records: records, statuses: statuses, askedAt: askedAt, kept: closed
                ))
                if statuses.count == recordsToAsk.count {
                    Defaults[.schoolDataSyncedAt] = Date()
                }
                // Rebuilt by every round, so a Home pull or a return to the app moves the
                // calendar's Moodle rows too, not only a launch or a calendar pull.
                var calendarEvents = DataCache.shared.loadCalendarEvents()
                calendarEvents.removeAll { $0.source == .moodle }
                calendarEvents.append(contentsOf: assignmentsToPersist.map(moodleCalendarEvent))
                DataCache.shared.saveCalendarEvents(calendarEvents)

                // Fire-and-forget: upload the assignment list to the backend
                // so it can populate its assignments table for cross-device
                // sync and notification scheduling.
                #if os(iOS)
                if Defaults[.cloudSyncEnabled] {
                    let iso = ISO8601DateFormatter()
                    iso.formatOptions = [.withInternetDateTime]
                    let entries = assignmentsToPersist.compactMap { a -> PushAPI.AssignmentUploadEntry? in
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
                    assignmentUploader?(PushAPI.AssignmentUploadRequest(assignments: entries))
                }
                #endif
            }
            // Sign-out reset the tracker, and the departing account's answer is not the next one's.
            if authService.loginGeneration == startGeneration {
                await MainActor.run { ServerStatusTracker.shared.set(.ok, for: .moodle) }
            }
            return assignmentsToPersist
        } catch {
            await MainActor.run {
                let note = (error as? MoodleWebserviceError) == .siteMaintenance ? error.localizedDescription : nil
                ServerStatusTracker.shared.set(.failed, for: .moodle, note: note)
                AppLogger.captureError(error, context: ["bridge": "fetchAssignments"])
            }
            return DataCache.shared.loadAssignments()
        }
    }

    /// A round's assignments, one per record with a due date and a submission, with the user's
    /// marks applied as `DataCache.loadAssignments` applies them.
    static func assignments(
        from records: [MoodleAssignmentRecord],
        moodleCoursesById: [Int: MoodleEnrolledCourse],
        courseNoByMoodleId: [Int: String],
        statuses: [Int: MoodleSubmissionStatus],
        confirmed: [String: Date],
        marks: AssignmentMarks
    ) -> [SDAssignment] {
        records.compactMap { record in
            guard let dueDate = record.dueDate else { return nil }
            guard !record.noSubmissions else { return nil }

            let moodleCourse = moodleCoursesById[record.courseId]
            let status = statuses[record.assignId]
            let assignmentId = String(record.assignId)
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
                submittedAt: status?.submittedAt ?? confirmedAt
            ))
        }
    }

    /// The records a round asks Moodle about. One without a due date or a submission is dropped
    /// from the list, Moodle keeps a submission it confirmed, and a `closed` one cannot change.
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

    /// When Moodle called each assignment unsubmitted in an answer asked for after its cutoff, by
    /// id. It takes no submission after the cutoff, so a round need not ask again until a teacher
    /// moves the cutoff past that answer. `askedAt` precedes the round's requests, and one left
    /// unanswered keeps its time from `kept`.
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
                if !status.isSubmitted, isClosed(record, askedAt: askedAt) { closed[id] = askedAt }
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
        // An assignment whose status request failed keeps its known `isCompleted` and
        // `submittedAt`, so the UI neither shows "not submitted" nor loses whether it was late.
        // One Moodle answered keeps the answer: a teacher may have reverted it to a draft.
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

    /// Matches the course number that leads a Moodle fullname, so
    /// `courseName(from:)` can strip it. Static so it compiles once, not per
    /// assignment.
    private static let courseNoPrefixRegex: NSRegularExpression = {
        // Anchored: must match the whole token.
        try! NSRegularExpression(pattern: "^3?[A-Z]{2}[A-Z0-9]{6,7}$")
    }()

    private static func courseName(from fullname: String) -> String {
        let parts = fullname.components(separatedBy: " ")
        guard parts.count >= 2 else { return fullname }

        if let index = parts.firstIndex(where: { part in
            let range = NSRange(part.startIndex..<part.endIndex, in: part)
            return courseNoPrefixRegex.firstMatch(in: part, range: range) != nil
        }), index + 1 < parts.count {
            return parts[(index + 1)...].joined(separator: " ")
        }

        return fullname
    }
}
