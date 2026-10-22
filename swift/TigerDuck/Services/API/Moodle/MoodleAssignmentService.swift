import Foundation

nonisolated enum MoodleAssignmentService {
    static let commentsFunction = "core_comment_get_comments"
    static let groupsFunction = "core_group_get_course_user_groups"

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

    static func fetchSubmissionStatus(assignId: Int) async throws -> MoodleSubmissionStatus {
        try await submissionStatus(assignId: assignId).toMoodleSubmissionStatus(assignId: assignId)
    }

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

    static let commentPageLimit = 10

    static func comments(
        cmid: Int,
        submissionId: Int,
        token: String,
        session: URLSession = MoodleWebserviceClient.session,
        siteURL: URL = AppConstants.moodleBaseURL
    ) async throws -> [MoodleSubmissionComment] {
        func page(_ number: Int) async throws -> RawComments {
            try await MoodleWebserviceClient.call(
                commentsFunction,
                params: [
                    ("contextlevel", "module"),
                    ("instanceid", String(cmid)),
                    ("component", "assignsubmission_comments"),
                    ("itemid", String(submissionId)),
                    ("area", "submission_comments"),
                    ("page", String(number)),
                ],
                token: token,
                as: RawComments.self,
                session: session,
                siteURL: siteURL
            )
        }
        var byId: [Int: MoodleSubmissionComment] = [:]
        var total = 0
        for number in 0..<commentPageLimit {
            let answer = try await page(number)
            let known = byId.count
            for comment in answer.comments { byId[comment.id] = comment.model }
            total = answer.count ?? 0
            guard byId.count > known, byId.count < total else { break }
        }
        if byId.count < total {
            for comment in try await page(0).comments { byId[comment.id] = comment.model }
        }
        return byId.values.sorted { ($0.created, $0.id) < ($1.created, $1.id) }
    }

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
    let feedback: Feedback?

    struct Feedback: Decodable {
        let gradefordisplay: String?
        let gradeddate: Int?
        let plugins: [LastAttempt.Plugin]?
    }

    private enum CodingKeys: String, CodingKey {
        case lastattempt, feedback
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastattempt = try container.decodeIfPresent(LastAttempt.self, forKey: .lastattempt)
        feedback = try? container.decodeIfPresent(Feedback.self, forKey: .feedback)
    }

    private var attempt: LastAttempt.Submission? {
        let own = lastattempt?.submission
        let team = lastattempt?.teamsubmission
        return team?.status == "submitted" || own?.status == nil ? team ?? own : own
    }

    func toMoodleSubmissionStatus(assignId: Int) -> MoodleSubmissionStatus {
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

    var submission: MoodleAssignmentSubmission {
        let record = attempt
        let plugins = record?.plugins ?? []
        return MoodleAssignmentSubmission(
            status: record?.status,
            modified: record?.timemodified.flatMap(Self.date),
            files: plugins.filter { $0.type == "file" }
                .flatMap { $0.fileareas ?? [] }
                .flatMap { $0.files ?? [] }
                .compactMap(\.model),
            onlineText: Self.text(of: plugins.first { $0.type == "onlinetext" }),
            id: record?.id,
            takesComments: plugins.contains { $0.type == "comments" },
            groupId: lastattempt?.submissiongroup,
            grade: grade
        )
    }

    private var grade: MoodleAssignmentGrade? {
        guard let feedback else { return nil }
        let shown = MoodleHTMLText.plainText(fromHTML: feedback.gradefordisplay ?? "")
        let grade = shown.isEmpty || shown == "-" ? nil : shown
        let comments = Self.text(of: feedback.plugins?.first { $0.type == "comments" })
        guard grade != nil || comments != nil else { return nil }
        return MoodleAssignmentGrade(grade: grade, gradedAt: feedback.gradeddate.flatMap(Self.date), feedback: comments)
    }

    private static func text(of plugin: LastAttempt.Plugin?) -> String? {
        guard let text = plugin?.editorfields?.first?.text else { return nil }
        let html = MoodleHTMLText.resolvingPluginFiles(
            in: text, files: (plugin?.fileareas ?? []).flatMap { $0.files ?? [] }.compactMap(\.model)
        )
        return MoodleHTMLText.markdown(fromHTML: html).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : html
    }

    private static func date(_ seconds: Int) -> Date? {
        seconds > 0 ? Date(timeIntervalSince1970: TimeInterval(seconds)) : nil
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
    let count: Int?
}

nonisolated private struct RawGroups: Decodable, Sendable {
    struct Group: Decodable, Sendable {
        let id: Int
        let name: String
    }

    let groups: [Group]
}
