import Foundation

enum MoodleAssignmentBridgeService {
    private static let siteBaseURL = URL(string: "https://moodle2.ntust.edu.tw")!
    private static let actionEventsFunction = "core_calendar_get_action_events_by_timesort"
    private static let actionEventsLimit = 100
    private static let assignmentLookbackDays = 7
    private static let webservicePath = "/webservice/rest/server.php"
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

    /// Fetch upcoming assignments via Moodle webservice.
    ///
    /// Runs on a long-lived Moodle Mobile App token — no NTUST session
    /// or credentials needed.
    static func fetchAssignments() async throws -> [SDAssignment] {
        let tokenService = MoodleTokenService.shared
        let token: String
        if let cached = await tokenService.currentToken() {
            token = cached
        } else {
            token = try await tokenService.refreshTokenIfNeeded()
        }

        let timesortFrom = assignmentTimesortFrom()

        do {
            let response = try await fetchActionEvents(
                using: token,
                timesortFrom: timesortFrom,
            )
            return mapAssignments(from: response.events)
        } catch MoodleWebserviceError.invalidToken {
            await tokenService.clearToken()
            let refreshedToken = try await tokenService.refreshTokenIfNeeded()
            let response = try await fetchActionEvents(
                using: refreshedToken,
                timesortFrom: timesortFrom,
            )
            return mapAssignments(from: response.events)
        }
    }

    // MARK: - mod_assign_get_assignments

    static func fetchAssignments(courseIds: [Int]) async throws -> [MoodleAssignmentRecord] {
        let tokenService = MoodleTokenService.shared
        if let token = await tokenService.currentToken() {
            do {
                return try await doFetchAssignments(token: token, courseIds: courseIds)
            } catch MoodleWebserviceError.invalidToken {
                await tokenService.clearToken()
                let refreshed = try await tokenService.refreshTokenIfNeeded()
                return try await doFetchAssignments(token: refreshed, courseIds: courseIds)
            }
        } else {
            let token = try await tokenService.refreshTokenIfNeeded()
            return try await doFetchAssignments(token: token, courseIds: courseIds)
        }
    }

    private static func doFetchAssignments(token: String, courseIds: [Int]) async throws -> [MoodleAssignmentRecord] {
        let body = courseIds
            .enumerated()
            .map { idx, cid in "courseids[\(idx)]=\(cid)" }
            .joined(separator: "&")
        let request = try makeWebserviceRequest(
            token: token,
            wsfunction: "mod_assign_get_assignments",
            body: body
        )
        let (data, _) = try await executeRequest(request)
        if let err = MoodleWebserviceError.from(jsonData: data) {
            throw err
        }
        do {
            let wrapper = try JSONDecoder().decode(RawAssignmentsResponse.self, from: data)
            return wrapper.toRecords()
        } catch {
            throw MoodleWebserviceError.malformedResponse(detail: "Unable to decode assignments: \(error)")
        }
    }

    // MARK: - mod_assign_get_submission_status

    static func fetchSubmissionStatus(assignId: Int) async throws -> MoodleSubmissionStatus {
        let tokenService = MoodleTokenService.shared
        let userId = try await MoodleSiteInfoService.shared.userId()
        if let token = await tokenService.currentToken() {
            do {
                return try await doFetchSubmissionStatus(token: token, assignId: assignId, userId: userId)
            } catch MoodleWebserviceError.invalidToken {
                await tokenService.clearToken()
                let refreshed = try await tokenService.refreshTokenIfNeeded()
                return try await doFetchSubmissionStatus(token: refreshed, assignId: assignId, userId: userId)
            }
        } else {
            let token = try await tokenService.refreshTokenIfNeeded()
            return try await doFetchSubmissionStatus(token: token, assignId: assignId, userId: userId)
        }
    }

    private static func doFetchSubmissionStatus(
        token: String,
        assignId: Int,
        userId: Int
    ) async throws -> MoodleSubmissionStatus {
        let body = "assignid=\(assignId)&userid=\(userId)"
        let request = try makeWebserviceRequest(
            token: token,
            wsfunction: "mod_assign_get_submission_status",
            body: body
        )
        let (data, _) = try await executeRequest(request)
        if let err = MoodleWebserviceError.from(jsonData: data) {
            throw err
        }
        do {
            let raw = try JSONDecoder().decode(RawSubmissionStatusResponse.self, from: data)
            return raw.toMoodleSubmissionStatus(assignId: assignId)
        } catch {
            throw MoodleWebserviceError.malformedResponse(detail: "Unable to decode submission status: \(error)")
        }
    }

    private static func fetchActionEvents(
        using token: String,
        timesortFrom: Int
    ) async throws -> BridgeMoodleCalendarResponse {
        let request = try makeActionEventsRequest(token: token, timesortFrom: timesortFrom)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await webserviceSession.data(for: request)
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

    private static func executeRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            let (data, response) = try await webserviceSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw MoodleWebserviceError.malformedResponse(detail: "No HTTP response")
            }
            guard httpResponse.statusCode == 200 else {
                if let moodleError = MoodleWebserviceError.from(jsonData: data) {
                    throw moodleError
                }
                throw MoodleWebserviceError.httpStatus(code: httpResponse.statusCode)
            }
            return (data, response)
        } catch let moodleError as MoodleWebserviceError {
            throw moodleError
        } catch let urlError as URLError {
            throw MoodleWebserviceError.transientNetwork(underlying: urlError.localizedDescription)
        } catch {
            throw error
        }
    }

    private static func makeActionEventsRequest(token: String, timesortFrom: Int) throws -> URLRequest {
        // Aligned 1:1 with backend/api/moodle/homework.py:
        //   POST /webservice/rest/server.php
        //     ?moodlewsrestformat=json&wsfunction=...&wstoken=...
        //   body: limitnum=<cap>&timesortfrom=<lookback>&limittononsuspendedevents=1
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
            "limitnum": String(actionEventsLimit),
            "timesortfrom": String(timesortFrom),
            "limittononsuspendedevents": "1",
        ])
        return request
    }

    private static func makeWebserviceRequest(
        token: String,
        wsfunction: String,
        body: String
    ) throws -> URLRequest {
        guard var components = URLComponents(url: siteBaseURL, resolvingAgainstBaseURL: false) else {
            throw MoodleWebserviceError.malformedResponse(detail: "invalid base URL")
        }
        components.path = webservicePath
        components.queryItems = [
            URLQueryItem(name: "moodlewsrestformat", value: "json"),
            URLQueryItem(name: "wsfunction", value: wsfunction),
            URLQueryItem(name: "wstoken", value: token),
        ]
        guard let url = components.url else {
            throw MoodleWebserviceError.malformedResponse(detail: "invalid webservice URL for \(wsfunction)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data(using: .utf8)
        return request
    }

    static func assignmentTimesortFrom(referenceDate: Date = Date()) -> Int {
        let lookbackDate = Calendar.current.date(
            byAdding: .day,
            value: -assignmentLookbackDays,
            to: referenceDate,
        ) ?? referenceDate
        return Int(lookbackDate.timeIntervalSince1970)
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
            guard event.modulename?.lowercased() == "assign" else { return nil }
            guard let dueTimestamp = event.timestart ?? event.timeusermidnight else {
                return nil
            }

            let courseNo = event.course.map { SDCourse.courseNoFromMoodleId($0.idnumber ?? "") } ?? ""
            let courseName = courseName(from: event.course?.fullname)
            let dueDate = Date(timeIntervalSince1970: TimeInterval(dueTimestamp))
            let moodleURL = event.url ?? event.action?.url
            let assignmentId = event.instance.map(String.init) ?? "event-\(event.id)"

            return SDAssignment(
                assignmentId: assignmentId,
                courseNo: courseNo,
                courseName: courseName,
                title: event.activityname ?? event.name,
                dueDate: dueDate,
                isCompleted: false,
                moodleUrl: moodleURL
            )
        }
    }

    static func courseName(from fullname: String?) -> String {
        guard let fullname else { return "" }

        let parts = fullname.components(separatedBy: " ")
        guard parts.count >= 2 else { return fullname }

        if let index = parts.firstIndex(where: {
            $0.range(of: "3?[A-Z]{2}[A-Z0-9]{6,7}", options: .regularExpression) != nil
        }), index + 1 < parts.count {
            return parts[(index + 1)...].joined(separator: " ")
        }

        return fullname
    }
}

private struct RawAssignmentsResponse: Decodable {
    struct Course: Decodable {
        let id: Int
        let assignments: [Assignment]

        struct Assignment: Decodable {
            let id: Int
            let cmid: Int
            let name: String
            let duedate: Int
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

private struct RawSubmissionStatusResponse: Decodable {
    struct LastAttempt: Decodable {
        let submission: Submission?
        let gradingstatus: String?

        struct Submission: Decodable {
            let status: String?
        }
    }

    let lastattempt: LastAttempt?

    func toMoodleSubmissionStatus(assignId: Int) -> MoodleSubmissionStatus {
        MoodleSubmissionStatus(
            assignId: assignId,
            submissionStatus: lastattempt?.submission?.status,
            gradingStatus: lastattempt?.gradingstatus
        )
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
