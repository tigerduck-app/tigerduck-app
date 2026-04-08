import Foundation

enum MoodleServiceError: LocalizedError {
    case notAuthenticated
    case sesskeyNotFound
    case invalidResponse
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Moodle 未登入"
        case .sesskeyNotFound: return "無法取得 Moodle sesskey"
        case .invalidResponse: return "Moodle 回應異常"
        case .networkError(let e): return "網路錯誤：\(e.localizedDescription)"
        }
    }
}

enum MoodleService {

    private static let moodleLoginURL = URL(string: "https://moodle2.ntust.edu.tw/login/index.php")!
    private static let moodleAPITemplate = "https://moodle2.ntust.edu.tw/lib/ajax/service.php?sesskey=%@&info=core_calendar_get_action_events_by_timesort"
    private static let sesskeyRegex = try! NSRegularExpression(pattern: "\"sesskey\":\"([^\"]+)\"")

    /// Fetch upcoming assignments from Moodle via SSO
    static func fetchAssignments(
        session: URLSession,
        studentId: String,
        password: String
    ) async throws -> [SDAssignment] {
        // Try fetching directly when cookies are valid (SSO session transfers across services).
        // Fall back to ensureServiceLogin if Moodle rejects us (no sesskey found).
        if !NTUSTSessionManager.shared.cookiesValid {
            let loggedIn = try await SSOLoginService.ensureServiceLogin(
                session: session,
                serviceURL: moodleLoginURL,
                studentId: studentId,
                password: password
            )
            guard loggedIn else { throw MoodleServiceError.notAuthenticated }
        }

        // Step 1: Visit Moodle to get sesskey
        let (pageData, _) = try await session.data(from: moodleLoginURL)
        guard let pageHTML = String(data: pageData, encoding: .utf8) else {
            throw MoodleServiceError.invalidResponse
        }

        // Extract sesskey — if missing, session is invalid; retry with full login
        var sesskey: String
        if let match = sesskeyRegex.firstMatch(in: pageHTML, range: NSRange(pageHTML.startIndex..., in: pageHTML)),
           let range = Range(match.range(at: 1), in: pageHTML) {
            sesskey = String(pageHTML[range])
        } else {
            // Session expired — re-authenticate to Moodle
            let loggedIn = try await SSOLoginService.ensureServiceLogin(
                session: session,
                serviceURL: moodleLoginURL,
                studentId: studentId,
                password: password
            )
            guard loggedIn else { throw MoodleServiceError.notAuthenticated }

            let (retryData, _) = try await session.data(from: moodleLoginURL)
            guard let retryHTML = String(data: retryData, encoding: .utf8) else {
                throw MoodleServiceError.invalidResponse
            }
            guard let retryMatch = sesskeyRegex.firstMatch(in: retryHTML, range: NSRange(retryHTML.startIndex..., in: retryHTML)),
                  let retryRange = Range(retryMatch.range(at: 1), in: retryHTML) else {
                throw MoodleServiceError.sesskeyNotFound
            }
            sesskey = String(retryHTML[retryRange])
        }

        // Step 3: Call Moodle calendar API
        let startOfToday = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        let apiURL = URL(string: String(format: moodleAPITemplate, sesskey))!

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = [MoodleCalendarRequest.upcoming(from: startOfToday)]
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, _) = try await session.data(for: request)
        let wrappers = try JSONDecoder().decode([MoodleCalendarWrapper].self, from: data)

        guard let first = wrappers.first, !first.error, let calData = first.data else {
            throw MoodleServiceError.invalidResponse
        }

        // Step 4: Map events to SDAssignment
        return calData.events.compactMap { event -> SDAssignment? in
            guard event.modulename == "assign" else { return nil }

            let courseNo = event.course.map { SDCourse.courseNoFromMoodleId($0.idnumber ?? "") } ?? ""

            let courseName: String
            if let fullname = event.course?.fullname {
                // Extract Chinese course name from format like "114.2【資工系】CS2006301 計算機組織 Computer Organization"
                let parts = fullname.components(separatedBy: " ")
                if parts.count >= 2 {
                    // Find the part after the course number
                    if let idx = parts.firstIndex(where: { $0.range(of: "3?[A-Z]{2}[A-Z0-9]{6,7}", options: .regularExpression) != nil }),
                       idx + 1 < parts.count {
                        courseName = parts[idx + 1]
                    } else {
                        courseName = fullname
                    }
                } else {
                    courseName = fullname
                }
            } else {
                courseName = ""
            }

            let dueDate = Date(timeIntervalSince1970: TimeInterval(event.timestart))

            return SDAssignment(
                assignmentId: "\(event.instance ?? event.id)",
                courseNo: courseNo,
                courseName: courseName,
                title: event.activityname ?? event.name,
                dueDate: dueDate,
                isCompleted: false,
                moodleUrl: event.url
            )
        }
    }
}
