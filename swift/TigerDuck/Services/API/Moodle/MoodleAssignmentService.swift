import Foundation

enum MoodleAssignmentService {

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

        func attempt(forceFreshToken: Bool) async throws -> MoodleSubmissionStatus {
            let token: String
            if forceFreshToken {
                token = try await tokenService.refreshTokenIfNeeded()
            } else if let cached = await tokenService.currentToken() {
                token = cached
            } else {
                token = try await tokenService.refreshTokenIfNeeded()
            }
            let userId = try await MoodleSiteInfoService.shared.userId()
            return try await doFetchSubmissionStatus(token: token, assignId: assignId, userId: userId)
        }

        do {
            return try await attempt(forceFreshToken: false)
        } catch MoodleWebserviceError.invalidToken {
            await tokenService.clearToken()
            return try await attempt(forceFreshToken: true)
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

    private static func executeRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            let (data, response) = try await MoodleWebserviceClient.session.data(for: request)
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

    private static func makeWebserviceRequest(
        token: String,
        wsfunction: String,
        body: String
    ) throws -> URLRequest {
        guard var components = URLComponents(url: MoodleWebserviceClient.siteBaseURL, resolvingAgainstBaseURL: false) else {
            throw MoodleWebserviceError.malformedResponse(detail: "invalid base URL")
        }
        components.path = MoodleWebserviceClient.webservicePath
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
                    cutoffDate: (assignment.cutoffdate ?? 0) > 0
                        ? Date(timeIntervalSince1970: TimeInterval(assignment.cutoffdate!))
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
