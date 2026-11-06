import Foundation

enum MoodleEnrolledCoursesService {
    static let answerFreshness = FreshnessPolicy(lifetime: 60)
    nonisolated static let usersCoursesFunction = "core_enrol_get_users_courses"

    private static var answer: (token: String?, startedAt: Date, task: Task<[MoodleEnrolledCourse], Error>)?

    static func fetchEnrolled() async throws -> [MoodleEnrolledCourse] {
        try await shared(token: await MoodleTokenService.shared.currentToken(), now: Date(), fetch: fetchUnshared)
    }

    static func shared(
        token: String?,
        now: Date,
        fetch: @escaping () async throws -> [MoodleEnrolledCourse]
    ) async throws -> [MoodleEnrolledCourse] {
        if let answer, answer.token == token, answerFreshness.isFresh(storedAt: answer.startedAt, now: now) {
            return try await answer.task.value
        }
        let task = Task { try await fetch() }
        answer = (token, now, task)
        do {
            return try await task.value
        } catch {
            if answer?.task == task { answer = nil }
            throw error
        }
    }

    static func dropSharedAnswer() {
        answer = nil
    }

    private static func fetchUnshared() async throws -> [MoodleEnrolledCourse] {
        try await MoodleWebserviceClient.withRenewingToken { token in
            let userId = try await MoodleSiteInfoService.shared.userId(token: token)
            return try await courses(of: userId, token: token)
        }
    }

    /// For another user, Moodle lists only the courses the account sees them in, past terms too.
    nonisolated static func courses(
        of userId: Int,
        token: String,
        session: URLSession = MoodleWebserviceClient.session,
        siteURL: URL = AppConstants.moodleBaseURL
    ) async throws -> [MoodleEnrolledCourse] {
        try await MoodleWebserviceClient.call(
            usersCoursesFunction,
            // Moodle otherwise counts every course's participants, which nothing here reads.
            params: [("userid", String(userId)), ("returnusercount", "0")],
            token: token,
            as: [RawMoodleEnrolledCourse].self,
            session: session,
            siteURL: siteURL
        ).map { $0.toMoodleEnrolledCourse() }
    }
}

nonisolated private struct RawMoodleEnrolledCourse: Decodable, Sendable {
    let id: Int
    let fullname: String?
    let shortname: String?
    let idnumber: String?
    let startdate: Int?
    let enddate: Int?

    func toMoodleEnrolledCourse() -> MoodleEnrolledCourse {
        MoodleEnrolledCourse(
            id: id,
            fullname: fullname ?? "",
            shortname: shortname ?? "",
            idnumber: idnumber ?? "",
            startDate: startdate.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            endDate: enddate.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }
}
