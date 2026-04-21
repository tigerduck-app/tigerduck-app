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

enum CourseSelectionService {
    private static let courseSelectionRoot = URL(string: "https://courseselection.ntust.edu.tw/")!
    private static let courseListURL = URL(string: "https://courseselection.ntust.edu.tw/ChooseList/D01/D01")!
    private static let courseNoRegex = /<tr>\s*<td>\s*(3?[A-Z][A-Z][A-Z0-9]{6,7})\s*<\/td>/

    static func fetchEnrolledCourseNos(
        session: URLSession,
        studentId: String,
        password: String,
        forceRefresh: Bool = false
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

        if let httpResp = response as? HTTPURLResponse,
           let finalURL = httpResp.url,
           finalURL.host?.contains("ssoam2.ntust.edu.tw") == true {
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
            if let retryResp = retryResponse as? HTTPURLResponse,
               let retryURL = retryResp.url,
               retryURL.host?.contains("ssoam2.ntust.edu.tw") == true {
                throw CourseServiceError.redirectedToSSO
            }
            let retryCourseNos = retryHTML.matches(of: courseNoRegex).map { String($0.1) }
            saveEnrolledCoursesCache(studentId: studentId, semester: semester, courseNos: retryCourseNos)
            return retryCourseNos
        }

        let courseNos = html.matches(of: courseNoRegex).map { String($0.1) }
        saveEnrolledCoursesCache(studentId: studentId, semester: semester, courseNos: courseNos)
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
