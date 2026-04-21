import Foundation

enum MoodleEnrolledCoursesService {
    private static let siteBaseURL = URL(string: "https://moodle2.ntust.edu.tw")!
    private static let webserviceUserAgent = (
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 "
            + "MoodleMobile 5.1.1 (51100)"
    )
    private static let webserviceSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = [
            "User-Agent": webserviceUserAgent,
            "Accept-Language": "zh-TW,zh;q=0.9,en-US;q=0.8,en;q=0.7",
        ]
        return URLSession(configuration: config)
    }()

    static func fetchEnrolled() async throws -> [MoodleEnrolledCourse] {
        let tokenService = MoodleTokenService.shared
        let token: String
        if let cached = await tokenService.currentToken() {
            token = cached
        } else {
            token = try await tokenService.refreshTokenIfNeeded()
        }

        let userId = try await MoodleSiteInfoService.shared.userId()

        do {
            return try await fetchEnrolledCourses(token: token, userId: userId)
        } catch MoodleWebserviceError.invalidToken {
            await tokenService.clearToken()
            let refreshedToken = try await tokenService.refreshTokenIfNeeded()
            return try await fetchEnrolledCourses(token: refreshedToken, userId: userId)
        }
    }

    private static func fetchEnrolledCourses(
        token: String,
        userId: Int
    ) async throws -> [MoodleEnrolledCourse] {
        guard var components = URLComponents(url: siteBaseURL, resolvingAgainstBaseURL: false) else {
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
        request.httpBody = wsFormBody(["userid": String(userId)])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await webserviceSession.data(for: request)
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
            throw MoodleWebserviceError.malformedResponse(detail: "Unable to decode enrolled courses response")
        }
    }

    private static func wsFormBody(_ fields: [String: String]) -> Data? {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return fields
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: unreserved) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
            .data(using: .utf8)
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
