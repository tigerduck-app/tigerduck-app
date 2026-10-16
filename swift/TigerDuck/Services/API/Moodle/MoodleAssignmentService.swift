import Foundation

nonisolated enum MoodleAssignmentService {
    static let commentsFunction = "core_comment_get_comments"
    static let groupsFunction = "core_group_get_course_user_groups"

    // MARK: - mod_assign_get_assignments

    /// Asks only for the courses where the user can submit, so Moodle leaves out a course they
    /// are a TA in, whose assignments they grade
    /// (https://github.com/tigerduck-app/tigerduck-app/issues/209).
    static func fetchAssignments(
        courseIds: [Int],
        tokens: MoodleWebserviceClient.TokenSource = .keychain,
        session: URLSession = MoodleWebserviceClient.session,
        siteURL: URL = AppConstants.moodleBaseURL
    ) async throws -> [MoodleAssignmentRecord] {
        try await MoodleWebserviceClient.withToken(tokens) { token in
            try await MoodleWebserviceClient.call(
                "mod_assign_get_assignments",
                params: courseIds.enumerated().map { ("courseids[\($0.offset)]", String($0.element)) }
                    + [("capabilities[0]", "mod/assign:submit")],
                token: token,
                as: RawAssignmentsResponse.self,
                session: session,
                siteURL: siteURL
            ).toRecords()
        }
    }

    // MARK: - mod_assign_get_submission_status

    static func fetchSubmissionStatus(assignId: Int) async throws -> MoodleSubmissionStatus {
        try await submissionStatus(assignId: assignId).toMoodleSubmissionStatus(assignId: assignId)
    }

    /// The account's submission as the assignment's page shows it.
    static func submission(assignId: Int) async throws -> MoodleAssignmentSubmission {
        try await submissionStatus(assignId: assignId).submission
    }

    private static func submissionStatus(assignId: Int) async throws -> RawSubmissionStatusResponse {
        try await MoodleWebserviceClient.withToken { token in
            let userId = try await MoodleSiteInfoService.shared.userId(token: token)
            return try await MoodleWebserviceClient.call(
                "mod_assign_get_submission_status",
                params: [("assignid", String(assignId)), ("userid", String(userId))],
                token: token,
                as: RawSubmissionStatusResponse.self
            )
        }
    }

    // MARK: - Comments and groups

    /// Moodle keeps a submission's comments on the assignment's module, under the submission's
    /// record. Oldest first, as a conversation reads.
    static func comments(
        cmid: Int,
        submissionId: Int,
        token: String,
        session: URLSession = MoodleWebserviceClient.session,
        siteURL: URL = AppConstants.moodleBaseURL
    ) async throws -> [MoodleSubmissionComment] {
        try await MoodleWebserviceClient.call(
            commentsFunction,
            params: [
                ("contextlevel", "module"),
                ("instanceid", String(cmid)),
                ("component", "assignsubmission_comments"),
                ("itemid", String(submissionId)),
                ("area", "submission_comments"),
            ],
            token: token,
            as: RawComments.self,
            session: session,
            siteURL: siteURL
        ).comments.map(\.model).sorted { ($0.created, $0.id) < ($1.created, $1.id) }
    }

    /// The groups the account is in on the course, by id.
    static func groups(
        courseId: Int,
        userId: Int,
        token: String,
        session: URLSession = MoodleWebserviceClient.session,
        siteURL: URL = AppConstants.moodleBaseURL
    ) async throws -> [Int: String] {
        let groups = try await MoodleWebserviceClient.call(
            groupsFunction,
            params: [("courseid", String(courseId)), ("userid", String(userId))],
            token: token,
            as: RawGroups.self,
            session: session,
            siteURL: siteURL
        ).groups
        return Dictionary(
            groups.map { ($0.id, MoodleHTMLText.plainText(fromHTML: $0.name)) },
            uniquingKeysWith: { first, _ in first }
        )
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
            let introattachments: [MoodleRawFile]?
            let nosubmissions: Int
            let teamsubmission: Int?
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
                    noSubmissions: assignment.nosubmissions != 0,
                    introAttachments: (assignment.introattachments ?? []).compactMap(\.model),
                    teamSubmission: (assignment.teamsubmission ?? 0) != 0
                )
            }
        }
    }
}

nonisolated struct RawSubmissionStatusResponse: Decodable, Sendable {
    struct LastAttempt: Decodable {
        let submission: Submission?
        let teamsubmission: Submission?
        let gradingstatus: String?
        let submissiongroup: Int?

        struct Submission: Decodable {
            let id: Int?
            let status: String?
            let timemodified: Int?
            let plugins: [Plugin]?
        }

        /// A submission plugin's part of the record: `file` lists files, `onlinetext` keeps its
        /// text in an editor field, and `comments` is there when the assignment takes them.
        struct Plugin: Decodable {
            let type: String?
            let fileareas: [FileArea]?
            let editorfields: [EditorField]?
        }

        struct FileArea: Decodable {
            let files: [MoodleRawFile]?
        }

        struct EditorField: Decodable {
            let text: String?
        }
    }

    let lastattempt: LastAttempt?

    func toMoodleSubmissionStatus(assignId: Int) -> MoodleSubmissionStatus {
        // A team assignment reports the group's status in `teamsubmission`, so a teammate's
        // submission leaves the student's own `submission` unsubmitted or without a status.
        let own = lastattempt?.submission
        let team = lastattempt?.teamsubmission
        let attempt = team?.status == "submitted" || own?.status == nil ? team ?? own : own
        let rawTime = attempt?.timemodified ?? 0
        let submittedAt: Date? = rawTime > 0
            ? Date(timeIntervalSince1970: TimeInterval(rawTime))
            : nil
        return MoodleSubmissionStatus(
            assignId: assignId,
            submissionStatus: attempt?.status,
            gradingStatus: lastattempt?.gradingstatus,
            submittedAt: submittedAt
        )
    }

    /// Moodle answers `teamsubmission` only for a team assignment, where the group's record holds
    /// what was handed in, as Moodle's own page shows it.
    var submission: MoodleAssignmentSubmission {
        let record = lastattempt?.teamsubmission ?? lastattempt?.submission
        let plugins = record?.plugins ?? []
        let text = plugins.first { $0.type == "onlinetext" }?.editorfields?.first?.text
        return MoodleAssignmentSubmission(
            status: record?.status,
            modified: record?.timemodified.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil },
            files: plugins.filter { $0.type == "file" }
                .flatMap { $0.fileareas ?? [] }
                .flatMap { $0.files ?? [] }
                .compactMap(\.model),
            onlineText: text.flatMap { MoodleHTMLText.plainText(fromHTML: $0).isEmpty ? nil : $0 },
            id: record?.id,
            takesComments: plugins.contains { $0.type == "comments" },
            groupId: lastattempt?.submissiongroup
        )
    }
}

nonisolated private struct RawComments: Decodable, Sendable {
    struct Comment: Decodable, Sendable {
        let id: Int
        let content: String?
        let timecreated: Int?
        let fullname: String?

        var model: MoodleSubmissionComment {
            MoodleSubmissionComment(
                id: id,
                authorName: fullname ?? "",
                created: Date(timeIntervalSince1970: TimeInterval(timecreated ?? 0)),
                content: content ?? ""
            )
        }
    }

    let comments: [Comment]
}

nonisolated private struct RawGroups: Decodable, Sendable {
    struct Group: Decodable, Sendable {
        let id: Int
        let name: String
    }

    let groups: [Group]
}
