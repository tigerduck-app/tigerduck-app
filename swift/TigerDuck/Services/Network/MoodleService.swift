import Foundation

enum MoodleService {

    private static let siteBaseURL = URL(string: "https://moodle2.ntust.edu.tw")!
    private static let actionEventsFunction = "core_calendar_get_action_events_by_timesort"

    /// Fetch upcoming assignments from Moodle webservice.
    static func fetchAssignments(
        session: URLSession,
        studentId: String,
        password: String
    ) async throws -> [SDAssignment] {
        _ = (studentId, password)

        let tokenService = MoodleTokenService.shared
        let token: String
        if let currentToken = await tokenService.currentToken() {
            token = currentToken
        } else {
            token = try await tokenService.refreshTokenIfNeeded()
        }

        do {
            let response = try await fetchActionEvents(
                using: token,
                session: session,
                timesortFrom: Int(Date().timeIntervalSince1970)
            )
            return mapAssignments(from: response.events)
        } catch MoodleWebserviceError.invalidToken {
            await tokenService.clearToken()
            let refreshedToken = try await tokenService.refreshTokenIfNeeded()
            let response = try await fetchActionEvents(
                using: refreshedToken,
                session: session,
                timesortFrom: Int(Date().timeIntervalSince1970)
            )
            return mapAssignments(from: response.events)
        }
    }

    private static func fetchActionEvents(
        using token: String,
        session: URLSession,
        timesortFrom: Int
    ) async throws -> MoodleCalendarResponse {
        let request = try makeActionEventsRequest(token: token, timesortFrom: timesortFrom)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw MoodleWebserviceError.transientNetwork(underlying: urlError.localizedDescription)
        } catch {
            throw error
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
            return try JSONDecoder().decode(MoodleCalendarResponse.self, from: data)
        } catch {
            throw MoodleWebserviceError.malformedResponse(detail: "Unable to decode action events response")
        }
    }

    private static func makeActionEventsRequest(token: String, timesortFrom: Int) throws -> URLRequest {
        guard var components = URLComponents(url: siteBaseURL, resolvingAgainstBaseURL: false) else {
            throw MoodleWebserviceError.malformedResponse(detail: "invalid base URL")
        }

        components.path = "/webservice/rest/server.php"
        components.queryItems = [
            URLQueryItem(name: "wstoken", value: token),
            URLQueryItem(name: "wsfunction", value: actionEventsFunction),
            URLQueryItem(name: "moodlewsrestformat", value: "json"),
            URLQueryItem(name: "limitnum", value: "50"),
            URLQueryItem(name: "timesortfrom", value: String(timesortFrom)),
        ]

        guard let url = components.url else {
            throw MoodleWebserviceError.malformedResponse(detail: "invalid action events URL")
        }

        return URLRequest(url: url)
    }

    private static func mapAssignments(from events: [MoodleCalendarEvent]) -> [SDAssignment] {
        events.compactMap { event in
            guard event.modulename == "assign" else { return nil }

            let courseNo = event.course.map { SDCourse.courseNoFromMoodleId($0.idnumber ?? "") } ?? ""
            let courseName = courseName(from: event.course?.fullname)
            let dueDate = Date(timeIntervalSince1970: TimeInterval(event.timestart ?? event.timeusermidnight ?? 0))
            let moodleURL = event.url ?? event.action?.url

            return SDAssignment(
                assignmentId: "\(event.instance ?? event.id)",
                courseNo: courseNo,
                courseName: courseName,
                title: event.activityname ?? event.name,
                dueDate: dueDate,
                isCompleted: false,
                moodleUrl: moodleURL
            )
        }
    }

    private static func courseName(from fullname: String?) -> String {
        guard let fullname else { return "" }

        let parts = fullname.components(separatedBy: " ")
        guard parts.count >= 2 else { return fullname }

        if let index = parts.firstIndex(where: {
            $0.range(of: "3?[A-Z]{2}[A-Z0-9]{6,7}", options: .regularExpression) != nil
        }), index + 1 < parts.count {
            return parts[index + 1]
        }

        return fullname
    }
}

private struct MoodleCalendarResponse: Decodable {
    let events: [MoodleCalendarEvent]
}

private struct MoodleCalendarEvent: Decodable {
    let id: Int
    let name: String
    let modulename: String?
    let activityname: String?
    let instance: Int?
    let timestart: Int?
    let timeusermidnight: Int?
    let course: MoodleCourseInfo?
    let action: MoodleAction?
    let url: String?
}
