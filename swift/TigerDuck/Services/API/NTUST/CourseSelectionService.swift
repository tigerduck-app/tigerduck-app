import Foundation
import os

enum CourseServiceError: LocalizedError {
    case notAuthenticated
    case redirectedToSSO(landedHost: String)
    case noCourseData
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return String(localized: "common_not_signed_in")
        case .redirectedToSSO: return String(localized: "error_session_expired")
        case .noCourseData: return String(localized: "error_courses_unavailable")
        case .networkError(let e): return String(format: String(localized: "error_network_format"), e.localizedDescription)
        }
    }
}

enum CourseSelectionService {
    /// Course selection's answer and when the school gave it.
    typealias LiveAnswer = (courseNos: [String], at: Date)

    private static let courseSelectionRoot = URL.knownGood("https://courseselection.ntust.edu.tw/")
    private static let courseListURL = URL.knownGood("https://courseselection.ntust.edu.tw/ChooseList/D01/D01")

    /// The enrolled course numbers, and whether they came from the school in this call rather than
    /// from the day-long cache.
    static func fetchEnrolledCourseNos(
        session: URLSession,
        studentId: String,
        password: String,
        forceRefresh: Bool = false,
        persistGuard: (@Sendable () -> Bool)? = nil
    ) async throws -> (courseNos: [String], live: Bool) {
        // The D01 page returns whichever term course selection is open for, which runs ahead
        // of the term in session, so cache under that term, not the month heuristic's guess.
        let semester = SemesterCatalog.selectionSemesterCode()
        if !forceRefresh, let cached = loadEnrolledCoursesCache(studentId: studentId, semester: semester) {
            return (cached, false)
        }

        let generation = NTUSTSessionManager.shared.generation
        if !(await NTUSTSessionManager.shared.probeCookiesValid()) {
            let loggedIn = try await SSOLoginService.ensureServiceLogin(
                session: session,
                serviceURL: courseSelectionRoot,
                studentId: studentId,
                password: password,
                generation: generation
            )
            guard loggedIn else { throw CourseServiceError.notAuthenticated }
        }

        let (data, response) = try await session.data(from: courseListURL)
        guard let html = String(data: data, encoding: .utf8) else {
            throw CourseServiceError.noCourseData
        }

        // Re-auth silently when the list came from another host (ssoam2, or the campus portal a
        // lapsed course-selection session is sent to) or as an SSO login body served inline
        // with HTTP 200. Either way the regex would fall through to "no courses".
        let landedElsewhere = (response as? HTTPURLResponse)?.url?.host != courseListURL.host
        let bodyIsSSO = HTMLParser.looksLikeSSOLoginBody(html)
        if landedElsewhere || bodyIsSSO {
            let landedHost = AppLogger.landedHost(response.url, service: courseListURL)
            var outcome = AppLogger.BounceOutcome.failed
            defer {
                AppLogger.serviceBounce(service: "courseList", landedHost: landedHost, ssoBody: bodyIsSSO, outcome: outcome)
            }
            NTUSTSessionManager.shared.dropServiceCookies(for: courseListURL)
            let loggedIn = try await SSOLoginService.ensureServiceLogin(
                session: session,
                serviceURL: courseSelectionRoot,
                studentId: studentId,
                password: password,
                generation: generation
            )
            guard loggedIn else { throw CourseServiceError.notAuthenticated }

            let (retryData, retryResponse) = try await session.data(from: courseListURL)
            guard let retryHTML = String(data: retryData, encoding: .utf8) else {
                throw CourseServiceError.noCourseData
            }
            let retryHost = (retryResponse as? HTTPURLResponse)?.url?.host
            if retryHost != courseListURL.host || HTMLParser.looksLikeSSOLoginBody(retryHTML) {
                outcome = .bouncedAgain
                throw CourseServiceError.redirectedToSSO(
                    landedHost: AppLogger.landedHost(retryResponse.url, service: courseListURL)
                )
            }
            outcome = .recovered
            let retryCourseNos = courseNos(inListPage: retryHTML)
            if persistGuard?() ?? true {
                saveEnrolledCoursesCache(studentId: studentId, semester: semester, courseNos: retryCourseNos)
            }
            return (retryCourseNos, true)
        }

        let courseNos = courseNos(inListPage: html)
        if persistGuard?() ?? true {
            saveEnrolledCoursesCache(studentId: studentId, semester: semester, courseNos: courseNos)
        }
        return (courseNos, true)
    }

    /// NTUST's course-number shape: a head, then six or seven letters or digits. The head is `3` and
    /// two letters, two letters, or `3` and one letter, as for a course taken at NTU or NTNU
    /// (https://github.com/tigerduck-app/tigerduck-app/issues/766).
    nonisolated static func isCourseNo(_ text: Substring) -> Bool {
        text.wholeMatch(of: /(?:3[A-Z]{2}|[A-Z]{2}|3[A-Z])[A-Z0-9]{6,7}/) != nil
    }

    nonisolated static func courseNos(inListPage html: String) -> [String] {
        html.matches(of: /<tr>\s*<td>\s*([A-Z0-9]+)\s*<\/td>/).map { String($0.1) }.filter { isCourseNo($0[...]) }
    }

    nonisolated static func needsSchoolSession(studentId: String, semester: String) -> Bool {
        semester == SemesterCatalog.selectionSemesterCode()
            && loadEnrolledCoursesCache(studentId: studentId, semester: semester) == nil
    }

    nonisolated static let enrolledCoursesCacheTTL: TimeInterval = 86_400

    nonisolated private static let enrolledCoursesCacheKey = "enrolledCourseNosCache"

    nonisolated private static let cacheLock = OSAllocatedUnfairLock()

    nonisolated private struct CachedCourseNos: Codable {
        let courseNos: [String]
        let cachedAt: TimeInterval
    }

    nonisolated static func invalidateEnrolledCoursesCache(for studentId: String? = nil) {
        cacheLock.withLock {
            let defaults = UserDefaults.standard
            guard let studentId else {
                defaults.removeObject(forKey: enrolledCoursesCacheKey)
                return
            }
            var dict = readCacheDict()
            dict = dict.filter { !$0.key.hasPrefix("\(studentId):") }
            writeCacheDict(dict)
        }
    }

    nonisolated private static func loadEnrolledCoursesCache(studentId: String, semester: String) -> [String]? {
        lastAnswer(studentId: studentId, semester: semester)?.courseNos
    }

    /// The term's last live answer while the day-long cache keeps it.
    nonisolated static func lastAnswer(studentId: String, semester: String) -> LiveAnswer? {
        cacheLock.withLock {
            let dict = readCacheDict()
            guard let entry = dict["\(studentId):\(semester)"] else { return nil }
            if Date().timeIntervalSince1970 - entry.cachedAt > enrolledCoursesCacheTTL { return nil }
            return (entry.courseNos, Date(timeIntervalSince1970: entry.cachedAt))
        }
    }

    nonisolated private static func saveEnrolledCoursesCache(studentId: String, semester: String, courseNos: [String]) {
        guard !courseNos.isEmpty else { return }
        cacheLock.withLock {
            var dict = readCacheDict()
            dict["\(studentId):\(semester)"] = CachedCourseNos(courseNos: courseNos, cachedAt: Date().timeIntervalSince1970)
            writeCacheDict(dict)
        }
    }

    nonisolated private static func readCacheDict() -> [String: CachedCourseNos] {
        guard let data = UserDefaults.standard.data(forKey: enrolledCoursesCacheKey),
              let dict = try? JSONDecoder().decode([String: CachedCourseNos].self, from: data) else {
            return [:]
        }
        return dict
    }

    nonisolated private static func writeCacheDict(_ dict: [String: CachedCourseNos]) {
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
        semesterCode(on: Date())
    }

    nonisolated static func semesterCode(on day: Date, calendar: AcademicCalendar = .cached) -> String {
        calendar.currentTerm(on: day)?.code ?? heuristicSemesterCode(on: day)
    }

    nonisolated static func heuristicSemesterCode(on day: Date) -> String {
        let cal = AcademicCalendar.calendar
        let year = cal.component(.year, from: day)
        let month = cal.component(.month, from: day)
        let rocYear = year - 1911

        if month >= 2 && month <= 7 {
            return "\(rocYear - 1)2"
        } else {
            let academicYear = month >= 8 ? rocYear : rocYear - 1
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
