import Foundation

enum CourseServiceError: LocalizedError {
    case notAuthenticated
    case redirectedToSSO
    case noCourseData
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "未登入"
        case .redirectedToSSO: return "登入已過期"
        case .noCourseData: return "無法取得課程資料"
        case .networkError(let e): return "網路錯誤：\(e.localizedDescription)"
        }
    }
}

enum CourseService {

    private static let courseSelectionRoot = URL(string: "https://courseselection.ntust.edu.tw/")!
    private static let courseListURL = URL(string: "https://courseselection.ntust.edu.tw/ChooseList/D01/D01")!
    private static let courseSearchAPI = URL(string: "https://querycourse.ntust.edu.tw/QueryCourse/api//courses")!

    private static let courseNoRegex = try! NSRegularExpression(
        pattern: "<tr>\\s*<td>\\s*(3?[A-Z]{2}[A-Z0-9]{6,7})\\s*</td>"
    )

    // MARK: - Fetch enrolled course numbers

    /// Login to course selection system and scrape enrolled course IDs
    static func fetchEnrolledCourseNos(
        session: URLSession,
        studentId: String,
        password: String
    ) async throws -> [String] {
        // Ensure logged in
        let loggedIn = try await SSOLoginService.ensureServiceLogin(
            session: session,
            serviceURL: courseSelectionRoot,
            studentId: studentId,
            password: password
        )
        guard loggedIn else { throw CourseServiceError.notAuthenticated }

        // Fetch course list page
        let (data, response) = try await session.data(from: courseListURL)
        guard let html = String(data: data, encoding: .utf8) else {
            throw CourseServiceError.noCourseData
        }

        // Check we didn't get redirected back to SSO
        if let httpResp = response as? HTTPURLResponse,
           let finalURL = httpResp.url,
           finalURL.host?.contains("ssoam2.ntust.edu.tw") == true {
            throw CourseServiceError.redirectedToSSO
        }

        let matches = courseNoRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        return matches.compactMap { match in
            guard let range = Range(match.range(at: 1), in: html) else { return nil }
            return String(html[range])
        }
    }

    // MARK: - Lookup course details from public API

    /// Call the NTUST course search API (public, no auth required)
    /// Returns all rows for the course (same course can have multiple time slots)
    static func lookupCourse(semester: String, courseNo: String) async throws -> [CourseSearchResult] {
        let requestBody = CourseSearchRequest.forCourseNo(courseNo, semester: semester)

        var request = URLRequest(url: courseSearchAPI)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode([CourseSearchResult].self, from: data)
    }

    /// Search courses by name (public API, no auth required)
    static func searchCourses(semester: String, courseName: String) async throws -> [CourseSearchResult] {
        let requestBody = CourseSearchRequest.forCourseName(courseName, semester: semester)

        var request = URLRequest(url: courseSearchAPI)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode([CourseSearchResult].self, from: data)
    }

    // MARK: - Parse Node to schedule

    /// Convert NTUST Node format "M6,M7,R10" to schedule dict [weekday: [periodId]]
    /// Day mapping: M=1(Mon), T=2(Tue), W=3(Wed), R=4(Thu), F=5(Fri), S=6(Sat), U=7(Sun)
    nonisolated static func parseNodeToSchedule(_ node: String?) -> [Int: [String]] {
        guard let node, !node.isEmpty else { return [:] }

        let dayMap: [Character: Int] = [
            "M": 1, "T": 2, "W": 3, "R": 4, "F": 5, "S": 6, "U": 7
        ]

        var schedule: [Int: [String]] = [:]

        for item in node.split(separator: ",") {
            let trimmed = item.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.first, let day = dayMap[first] else { continue }
            let periodId = String(trimmed.dropFirst())
            guard !periodId.isEmpty else { continue }
            schedule[day, default: []].append(periodId)
        }

        return schedule
    }

    // MARK: - Current semester

    /// Compute current NTUST semester code (e.g. "1142" for spring 2025-2026)
    static func currentSemesterCode() -> String {
        let cal = Calendar.current
        let now = Date()
        let year = cal.component(.year, from: now)
        let month = cal.component(.month, from: now)
        let rocYear = year - 1911

        // Sep-Jan = semester 1, Feb-Aug = semester 2
        if month >= 2 && month <= 8 {
            // Spring semester, academic year = rocYear - 1
            return "\(rocYear - 1)2"
        } else {
            // Fall semester
            let academicYear = month >= 9 ? rocYear : rocYear - 1
            return "\(academicYear)1"
        }
    }
}
