import Foundation

enum CourseServiceError: LocalizedError {
    case notAuthenticated
    case redirectedToSSO
    case noCourseData
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return String(localized: "common_not_logged_in")
        case .redirectedToSSO: return String(localized: "error_session_expired")
        case .noCourseData: return String(localized: "error_courses_unavailable")
        case .networkError(let e): return String(format: String(localized: "error_network_format"), e.localizedDescription)
        }
    }
}

enum CourseSelectionService {
    private static let courseSelectionRoot = URL.knownGood("https://courseselection.ntust.edu.tw/")
    private static let courseListURL = URL.knownGood("https://courseselection.ntust.edu.tw/ChooseList/D01/D01")
    private static let courseNoRegex = /<tr>\s*<td>\s*(3?[A-Z][A-Z][A-Z0-9]{6,7})\s*<\/td>/

    static func fetchEnrolledCourseNos(
        session: URLSession,
        studentId: String,
        password: String,
        forceRefresh: Bool = false,
        persistGuard: (@Sendable () -> Bool)? = nil
    ) async throws -> [String] {
        let semester = currentSemesterCode()
        if !forceRefresh, let cached = loadEnrolledCoursesCache(studentId: studentId, semester: semester) {
            return cached
        }

        if !(await NTUSTSessionManager.shared.probeCookiesValid()) {
            let loggedIn = try await SSOLoginService.ensureServiceLogin(
                session: session,
                serviceURL: courseSelectionRoot,
                studentId: studentId,
                password: password
            )
            guard loggedIn else { throw CourseServiceError.notAuthenticated }
        }

        let (data, response) = try await session.data(from: courseListURL)
        guard let html = String(data: data, encoding: .utf8) else {
            throw CourseServiceError.noCourseData
        }

        // Trigger silent re-auth on either an ssoam2 redirect *or* an
        // inline-rendered SSO login body returned with HTTP 200 from
        // the course-selection host. URL-only detection misses the
        // inline case and the regex falls through to "no courses".
        let landedOnSSO = (response as? HTTPURLResponse)?.url?.host == "ssoam2.ntust.edu.tw"
        let bodyIsSSO = HTMLParser.looksLikeSSOLoginBody(html)
        if landedOnSSO || bodyIsSSO {
            let loggedIn = try await SSOLoginService.ensureServiceLogin(
                session: session,
                serviceURL: courseSelectionRoot,
                studentId: studentId,
                password: password
            )
            guard loggedIn else { throw CourseServiceError.notAuthenticated }

            let (retryData, retryResponse) = try await session.data(from: courseListURL)
            guard let retryHTML = String(data: retryData, encoding: .utf8) else {
                throw CourseServiceError.noCourseData
            }
            let retryHost = (retryResponse as? HTTPURLResponse)?.url?.host
            if retryHost == "ssoam2.ntust.edu.tw" || HTMLParser.looksLikeSSOLoginBody(retryHTML) {
                throw CourseServiceError.redirectedToSSO
            }
            let retryCourseNos = retryHTML.matches(of: courseNoRegex).map { String($0.1) }
            // Guarded write: see persistGuard rationale on
            // NTUSTScoreService.fetchScoreReport — same in-flight
            // logout / account-swap protection.
            if persistGuard?() ?? true {
                saveEnrolledCoursesCache(studentId: studentId, semester: semester, courseNos: retryCourseNos)
            }
            return retryCourseNos
        }

        let courseNos = html.matches(of: courseNoRegex).map { String($0.1) }
        if persistGuard?() ?? true {
            saveEnrolledCoursesCache(studentId: studentId, semester: semester, courseNos: courseNos)
        }
        return courseNos
    }

    static let enrolledCoursesCacheTTL: TimeInterval = 86_400

    private static let enrolledCoursesCacheKey = "enrolledCourseNosCache"

    private struct CachedCourseNos: Codable {
        let courseNos: [String]
        let cachedAt: TimeInterval
    }

    static func invalidateEnrolledCoursesCache(for studentId: String? = nil) {
        let defaults = UserDefaults.standard
        guard let studentId else {
            defaults.removeObject(forKey: enrolledCoursesCacheKey)
            return
        }
        var dict = readCacheDict()
        dict = dict.filter { !$0.key.hasPrefix("\(studentId):") }
        writeCacheDict(dict)
    }

    private static func loadEnrolledCoursesCache(studentId: String, semester: String) -> [String]? {
        let dict = readCacheDict()
        guard let entry = dict["\(studentId):\(semester)"] else { return nil }
        if Date().timeIntervalSince1970 - entry.cachedAt > enrolledCoursesCacheTTL { return nil }
        return entry.courseNos
    }

    private static func saveEnrolledCoursesCache(studentId: String, semester: String, courseNos: [String]) {
        guard !courseNos.isEmpty else { return }
        var dict = readCacheDict()
        dict["\(studentId):\(semester)"] = CachedCourseNos(courseNos: courseNos, cachedAt: Date().timeIntervalSince1970)
        writeCacheDict(dict)
    }

    private static func readCacheDict() -> [String: CachedCourseNos] {
        guard let data = UserDefaults.standard.data(forKey: enrolledCoursesCacheKey),
              let dict = try? JSONDecoder().decode([String: CachedCourseNos].self, from: data) else {
            return [:]
        }
        return dict
    }

    private static func writeCacheDict(_ dict: [String: CachedCourseNos]) {
        let defaults = UserDefaults.standard
        if dict.isEmpty {
            defaults.removeObject(forKey: enrolledCoursesCacheKey)
            return
        }
        if let data = try? JSONEncoder().encode(dict) {
            defaults.set(data, forKey: enrolledCoursesCacheKey)
        }
    }

    nonisolated static func currentSemesterCode() -> String {
        let cal = Calendar.current
        let now = Date()
        let year = cal.component(.year, from: now)
        let month = cal.component(.month, from: now)
        let rocYear = year - 1911

        if month >= 2 && month <= 8 {
            return "\(rocYear - 1)2"
        } else {
            let academicYear = month >= 9 ? rocYear : rocYear - 1
            return "\(academicYear)1"
        }
    }

    nonisolated static func previousSemesterCode(_ semester: String) -> String {
        guard semester.count >= 2 else { return semester }

        let yearPart = String(semester.dropLast())
        let semesterPart = String(semester.suffix(1))

        guard let year = Int(yearPart), let term = Int(semesterPart) else {
            return semester
        }

        if term <= 1 {
            return "\(year - 1)2"
        }

        return "\(year)1"
    }
}
