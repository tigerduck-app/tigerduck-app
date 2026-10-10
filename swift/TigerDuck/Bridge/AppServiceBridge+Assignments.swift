import Defaults
import Foundation

extension AppServiceBridge {

    /// `recheckSubmissions` asks Moodle about every submission. Without it a round skips the
    /// ones ``confirmedSubmissions(in:)`` lists, so a pull is what shows a reverted submission.
    static func fetchAssignments(authService: AuthService, recheckSubmissions: Bool = false) async -> [SDAssignment] {
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
                relevantCourses = moodleEnrolled.filter { currentCourseNos.contains($0.courseNo) }
            }
            let relevantMoodleCourseIds = relevantCourses.map(\.id)
            guard !relevantMoodleCourseIds.isEmpty else {
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
            // Records without a due date or a submission are dropped below, so asking about
            // them would only cost Moodle a request.
            let recordsToAsk = records.filter {
                $0.dueDate != nil && !$0.noSubmissions && confirmed[String($0.assignId)] == nil
            }
            let statuses: [Int: MoodleSubmissionStatus] = await withTaskGroup(
                of: (Int, MoodleSubmissionStatus)?.self,
                returning: [Int: MoodleSubmissionStatus].self
            ) { group in
                for record in recordsToAsk {
                    group.addTask {
                        guard let status = try? await MoodleAssignmentService.fetchSubmissionStatus(
                            assignId: record.assignId
                        ) else {
                            return nil
                        }
                        return (record.assignId, status)
                    }
                }

                var result: [Int: MoodleSubmissionStatus] = [:]
                for await pair in group {
                    if let (id, status) = pair {
                        result[id] = status
                    }
                }
                return result
            }

            let locallyCompletedIds = DataCache.shared.loadLocallyCompletedAssignmentIds()
            let archivedIds = DataCache.shared.loadArchivedAssignmentIds()

            let freshAssignments: [SDAssignment] = records.compactMap { record in
                guard let dueDate = record.dueDate else { return nil }
                guard !record.noSubmissions else { return nil }

                let moodleCourse = moodleCoursesById[record.courseId]
                let status = statuses[record.assignId]
                let assignmentId = String(record.assignId)
                let confirmedAt = confirmed[assignmentId]
                return SDAssignment(
                    assignmentId: assignmentId,
                    courseNo: moodleCourse.flatMap { courseNoByMoodleId[$0.id] } ?? "",
                    courseName: moodleCourse.map { courseName(from: $0.fullname) } ?? "",
                    title: record.name,
                    dueDate: dueDate,
                    isCompleted: status?.isSubmitted ?? (confirmedAt != nil),
                    isArchived: archivedIds.contains(assignmentId),
                    isLocallyCompleted: locallyCompletedIds.contains(assignmentId),
                    moodleUrl: "https://moodle2.ntust.edu.tw/mod/assign/view.php?id=\(record.cmId)",
                    cutoffDate: record.cutoffDate,
                    submittedAt: status?.submittedAt ?? confirmedAt
                )
            }

            let assignmentsToPersist: [SDAssignment]
            if statuses.count < recordsToAsk.count {
                assignmentsToPersist = preserveCompletionState(
                    freshAssignments: freshAssignments,
                    cachedAssignments: cachedAssignments
                )
            } else {
                assignmentsToPersist = freshAssignments
            }

            if !Task.isCancelled,
               authService.loginGeneration == startGeneration {
                DataCache.shared.saveAssignments(assignmentsToPersist)

                // Fire-and-forget: upload the assignment list to the backend
                // so it can populate its assignments table for cross-device
                // sync and notification scheduling.
                #if os(iOS)
                if Defaults[.cloudSyncEnabled], let atm = authService.authTokenManager {
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
                    let client = PushAPIClient(
                        authHeaderProvider: { await atm.authorizationHeader() }
                    )
                    Task.detached {
                        try? await client.uploadAssignments(
                            PushAPI.AssignmentUploadRequest(assignments: entries)
                        )
                    }
                }
                #endif
            }
            await MainActor.run { ServerStatusTracker.shared.set(.ok, for: .moodle) }
            return assignmentsToPersist
        } catch {
            await MainActor.run {
                ServerStatusTracker.shared.set(.failed, for: .moodle)
                AppLogger.captureError(error, context: ["bridge": "fetchAssignments"])
            }
            return DataCache.shared.loadAssignments()
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
        cachedAssignments: [SDAssignment]
    ) -> [SDAssignment] {
        // A partial submission-status failure keeps the known `isCompleted`, so the UI
        // does not regress from "submitted" to "not submitted". Keep `submittedAt` too,
        // or "submitted" and "submitted late" cannot be told apart afterwards.
        let previousById = Dictionary(
            uniqueKeysWithValues: cachedAssignments.map { ($0.assignmentId, $0) }
        )

        for assignment in freshAssignments {
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
