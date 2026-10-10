import Foundation

enum MoodleEnrolledCoursesService {
    /// One answer serves every caller under the same wstoken for this long: a launch asks
    /// from both the assignment and the course fetch, and a class-table pull from both at once.
    static let answerLifetime: TimeInterval = 60

    private static var answer: (token: String?, startedAt: Date, task: Task<[MoodleEnrolledCourse], Error>)?

    static func fetchEnrolled() async throws -> [MoodleEnrolledCourse] {
        try await shared(token: await MoodleTokenService.shared.currentToken(), now: Date(), fetch: fetchUnshared)
    }

    /// Joins the request in flight or reuses the last answer while both belong to `token` and
    /// are under ``answerLifetime`` old; a failure is never kept.
    static func shared(
        token: String?,
        now: Date,
        fetch: @escaping () async throws -> [MoodleEnrolledCourse]
    ) async throws -> [MoodleEnrolledCourse] {
        if let answer, answer.token == token, now.timeIntervalSince(answer.startedAt) < answerLifetime {
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

    /// The next caller starts a new request. A pull calls this before it fetches.
    static func dropSharedAnswer() {
        answer = nil
    }

    private static func fetchUnshared() async throws -> [MoodleEnrolledCourse] {
        let tokenService = MoodleTokenService.shared

        func attempt(forceFreshToken: Bool) async throws -> [MoodleEnrolledCourse] {
            let token: String
            if forceFreshToken {
                token = try await tokenService.refreshTokenIfNeeded()
            } else if let cached = await tokenService.currentToken() {
                token = cached
            } else {
                token = try await tokenService.refreshTokenIfNeeded()
            }
            // `userId(token:)` calls core_webservice_get_site_info with the same token, so it
            // stays inside the retry block: outside it, a stale token's `.invalidToken` from
            // site_info would skip the refresh path and fail the whole call.
            let userId = try await MoodleSiteInfoService.shared.userId(token: token)
            return try await fetchEnrolledCourses(token: token, userId: userId)
        }

        do {
            return try await attempt(forceFreshToken: false)
        } catch MoodleWebserviceError.invalidToken {
            await tokenService.clearToken()
            return try await attempt(forceFreshToken: true)
        }
    }

    private static func fetchEnrolledCourses(
        token: String,
        userId: Int
    ) async throws -> [MoodleEnrolledCourse] {
        guard var components = URLComponents(url: MoodleWebserviceClient.siteBaseURL, resolvingAgainstBaseURL: false) else {
            throw MoodleWebserviceError.malformedResponse(detail: "invalid enrolled courses URL")
        }
        components.path = "/webservice/rest/server.php"
        components.queryItems = [
            URLQueryItem(name: "moodlewsrestformat", value: "json"),
            URLQueryItem(name: "wsfunction", value: "core_enrol_get_users_courses"),
            URLQueryItem(name: "wstoken", value: token),
        ]

        guard let url = components.url else {
            throw MoodleWebserviceError.malformedResponse(detail: "invalid enrolled courses URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = try wsFormBody(["userid": String(userId)])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await MoodleWebserviceClient.session.data(for: request)
        } catch let urlError as URLError {
            throw MoodleWebserviceError.transientNetwork(underlying: urlError.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MoodleWebserviceError.malformedResponse(detail: "No HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            if let moodleError = MoodleWebserviceError.from(jsonData: data) {
                throw moodleError
            }
            throw MoodleWebserviceError.httpStatus(code: httpResponse.statusCode)
        }

        if let moodleError = MoodleWebserviceError.from(jsonData: data) {
            throw moodleError
        }

        do {
            let courses = try JSONDecoder().decode([RawMoodleEnrolledCourse].self, from: data)
            return courses.map { $0.toMoodleEnrolledCourse() }
        } catch {
            throw MoodleWebserviceError.malformedResponse(detail: "Unable to decode enrolled courses response: \(error)")
        }
    }

    private static func wsFormBody(_ fields: [String: String]) throws -> Data {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        let encoded = fields
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: unreserved) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
        guard let data = encoded.data(using: .utf8) else {
            throw MoodleWebserviceError.malformedResponse(detail: "wsFormBody: utf8 encoding failed")
        }
        return data
    }
}

private struct RawMoodleEnrolledCourse: Decodable {
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
