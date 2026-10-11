import Foundation

enum MoodleAssignmentService {

    // MARK: - mod_assign_get_assignments

    static func fetchAssignments(courseIds: [Int]) async throws -> [MoodleAssignmentRecord] {
        try await MoodleWebserviceClient.withToken { token in
            try await MoodleWebserviceClient.call(
                "mod_assign_get_assignments",
                params: courseIds.enumerated().map { ("courseids[\($0.offset)]", String($0.element)) },
                token: token,
                as: RawAssignmentsResponse.self
            ).toRecords()
        }
    }

    // MARK: - mod_assign_get_submission_status

    static func fetchSubmissionStatus(assignId: Int) async throws -> MoodleSubmissionStatus {
        try await MoodleWebserviceClient.withToken { token in
            let userId = try await MoodleSiteInfoService.shared.userId(token: token)
            return try await MoodleWebserviceClient.call(
                "mod_assign_get_submission_status",
                params: [("assignid", String(assignId)), ("userid", String(userId))],
                token: token,
                as: RawSubmissionStatusResponse.self
            ).toMoodleSubmissionStatus(assignId: assignId)
        }
    }
}

nonisolated private struct RawAssignmentsResponse: Decodable, Sendable {
    struct Course: Decodable {
        let id: Int
        let assignments: [Assignment]

        struct Assignment: Decodable {
            let id: Int
            let cmid: Int
            let name: String
            let duedate: Int
            let cutoffdate: Int?
            let allowsubmissionsfromdate: Int
            let intro: String?
            let nosubmissions: Int
        }
    }

    let courses: [Course]

    func toRecords() -> [MoodleAssignmentRecord] {
        courses.flatMap { course in
            course.assignments.map { assignment in
                MoodleAssignmentRecord(
                    assignId: assignment.id,
                    cmId: assignment.cmid,
                    courseId: course.id,
                    name: assignment.name,
                    dueDate: assignment.duedate > 0
                        ? Date(timeIntervalSince1970: TimeInterval(assignment.duedate))
                        : nil,
                    cutoffDate: {
                        guard let cd = assignment.cutoffdate, cd > 0 else { return nil }
                        return Date(timeIntervalSince1970: TimeInterval(cd))
                    }(),
                    allowSubmissionsFromDate: assignment.allowsubmissionsfromdate > 0
                        ? Date(timeIntervalSince1970: TimeInterval(assignment.allowsubmissionsfromdate))
                        : nil,
                    intro: assignment.intro ?? "",
                    noSubmissions: assignment.nosubmissions != 0
                )
            }
        }
    }
}

nonisolated private struct RawSubmissionStatusResponse: Decodable, Sendable {
    struct LastAttempt: Decodable {
        let submission: Submission?
        let gradingstatus: String?

        struct Submission: Decodable {
            let status: String?
            let timemodified: Int?
        }
    }

    let lastattempt: LastAttempt?

    func toMoodleSubmissionStatus(assignId: Int) -> MoodleSubmissionStatus {
        let rawTime = lastattempt?.submission?.timemodified ?? 0
        let submittedAt: Date? = rawTime > 0
            ? Date(timeIntervalSince1970: TimeInterval(rawTime))
            : nil
        return MoodleSubmissionStatus(
            assignId: assignId,
            submissionStatus: lastattempt?.submission?.status,
            gradingStatus: lastattempt?.gradingstatus,
            submittedAt: submittedAt
        )
    }
}
