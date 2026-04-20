import Foundation

enum MoodleAssignmentBridgeService {
    private static let siteBaseURL = URL(string: "https://moodle2.ntust.edu.tw")!
    private static let actionEventsFunction = "core_calendar_get_action_events_by_timesort"

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
    ) async throws -> BridgeMoodleCalendarResponse {
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
            return try JSONDecoder().decode(BridgeMoodleCalendarResponse.self, from: data)
        } catch {
            throw MoodleWebserviceError.malformedResponse(detail: "Unable to decode action events response")
        }
    }

    private static func makeActionEventsRequest(token: String, timesortFrom: Int) throws -> URLRequest {
        // Aligned 1:1 with backend/api/moodle/homework.py:
        //   POST /webservice/rest/server.php
        //     ?moodlewsrestformat=json&wsfunction=...&wstoken=...
        //   body: limitnum=50&timesortfrom=<now>&limittononsuspendedevents=1
        guard var components = URLComponents(url: siteBaseURL, resolvingAgainstBaseURL: false) else {
            throw MoodleWebserviceError.malformedResponse(detail: "invalid base URL")
        }
        components.path = "/webservice/rest/server.php"
        components.queryItems = [
            URLQueryItem(name: "moodlewsrestformat", value: "json"),
            URLQueryItem(name: "wsfunction", value: actionEventsFunction),
            URLQueryItem(name: "wstoken", value: token),
        ]
        guard let url = components.url else {
            throw MoodleWebserviceError.malformedResponse(detail: "invalid action events URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = wsFormBody([
            "limitnum": "50",
            "timesortfrom": String(timesortFrom),
            "limittononsuspendedevents": "1",
        ])
        return request
    }

    private static func wsFormBody(_ fields: [String: String]) -> Data? {
        // RFC-3986 unreserved only — safe for any value.
        let unreserved = CharacterSet(
            charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~",
        )
        return fields
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: unreserved) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
            .data(using: .utf8)
    }

    private static func mapAssignments(from events: [BridgeMoodleCalendarEvent]) -> [SDAssignment] {
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

private struct BridgeMoodleCalendarResponse: Decodable {
    let events: [BridgeMoodleCalendarEvent]
}

private struct BridgeMoodleCalendarEvent: Decodable {
    let id: Int
    let name: String
    let modulename: String?
    let activityname: String?
    let instance: Int?
    let timestart: Int?
    let timeusermidnight: Int?
    let course: BridgeMoodleCourseInfo?
    let action: BridgeMoodleAction?
    let url: String?
}

private struct BridgeMoodleCourseInfo: Decodable {
    let idnumber: String?
    let fullname: String?
}

private struct BridgeMoodleAction: Decodable {
    let url: String?
}
