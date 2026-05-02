import Foundation

enum NTUSTScoreServiceError: LocalizedError {
    case notAuthenticated
    case redirectedToSSO
    case invalidResponse
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return String(localized: "common_not_logged_in")
        case .redirectedToSSO:  return String(localized: "error_session_expired")
        case .invalidResponse:  return String(localized: "error_invalid_server_response")
        case .parseFailed:      return String(localized: "score_error_parse_failed")
        }
    }
}

/// Fetches the NTUST StuScoreQueryServ "DisplayAll" HTML, parses it into a
/// ``ScoreReport``, and caches the result on disk for up to 24h.
///
/// Mirrors the cache + SSO retry flow of ``CourseSelectionService`` so users
/// of cached-first gates get consistent behavior across screens.
enum NTUSTScoreService {
    private static let scoreRootURL = URL(string: "https://stuinfosys.ntust.edu.tw/StuScoreQueryServ/")!
    private static let scoreDisplayURL = URL(
        string: "https://stuinfosys.ntust.edu.tw/StuScoreQueryServ/StuScoreQuery/DisplayAll"
    )!

    /// Disk-cache TTL before the service refetches the live HTML. Mirrors the
    /// CourseSelectionService 24h window — deliberately long because grade
    /// updates are a weeks-to-months cadence, so stale-hit dominates.
    static let scoreReportCacheTTL: TimeInterval = 86_400

    /// Load the student's score report. Honors a 24h disk cache unless
    /// `forceRefresh` is set (e.g. pull-to-refresh, which shares the same
    /// semantics as ``CourseSelectionService.fetchEnrolledCourseNos``).
    static func fetchScoreReport(
        session: URLSession,
        studentId: String,
        password: String,
        forceRefresh: Bool = false
    ) async throws -> ScoreReport {
        if !forceRefresh,
           let cached = DataCache.shared.loadScoreReport(studentId: studentId),
           Date().timeIntervalSince(cached.cachedAt) < scoreReportCacheTTL {
            return cached.report
        }

        if !(await NTUSTSessionManager.shared.probeCookiesValid()) {
            let loggedIn = try await SSOLoginService.ensureServiceLogin(
                session: session,
                serviceURL: scoreRootURL,
                studentId: studentId,
                password: password
            )
            guard loggedIn else { throw NTUSTScoreServiceError.notAuthenticated }
        }

        let html = try await fetchHTML(session: session, studentId: studentId, password: password)
        let report = NTUSTScoreParser.parse(html: html)

        // Defensive: a successful fetch that parses to a fully empty report
        // usually means the HTML was actually the SSO page disguised as a
        // 200 — avoid poisoning the cache with that.
        if report == .empty {
            throw NTUSTScoreServiceError.parseFailed
        }

        DataCache.shared.saveScoreReport(report, studentId: studentId)
        return report
    }

    /// Cached snapshot without the network call. Used by the view model to
    /// render instantly on first appearance while a background refresh runs.
    static func cachedScoreReport(studentId: String) -> (report: ScoreReport, cachedAt: Date)? {
        DataCache.shared.loadScoreReport(studentId: studentId)
    }

    static func invalidateCache(studentId: String) {
        DataCache.shared.invalidateScoreReport(studentId: studentId)
    }

    // MARK: - Private

    private static func fetchHTML(
        session: URLSession,
        studentId: String,
        password: String
    ) async throws -> String {
        let (data, response) = try await session.data(from: scoreDisplayURL)
        guard let html = String(data: data, encoding: .utf8) else {
            throw NTUSTScoreServiceError.invalidResponse
        }

        // SSO bounced us — try one silent re-login and retry once.
        // Trigger on either (a) URL host became ssoam2 (the obvious 302
        // redirect) OR (b) the body itself looks like the SSO login
        // form rendered inline on stuinfosys (200 with login HTML — has
        // happened during Shibboleth maintenance windows). Without (b)
        // the parser falls through and the user sees a confusing
        // "parse failed" instead of a re-auth prompt.
        let landedOnSSO = (response as? HTTPURLResponse)?.url?.host == "ssoam2.ntust.edu.tw"
        let bodyIsSSO = HTMLParser.looksLikeSSOLoginBody(html)
        if landedOnSSO || bodyIsSSO {
            let loggedIn = try await SSOLoginService.ensureServiceLogin(
                session: session,
                serviceURL: scoreRootURL,
                studentId: studentId,
                password: password
            )
            guard loggedIn else { throw NTUSTScoreServiceError.notAuthenticated }

            let (retryData, retryResp) = try await session.data(from: scoreDisplayURL)
            guard let retryHTML = String(data: retryData, encoding: .utf8) else {
                throw NTUSTScoreServiceError.invalidResponse
            }
            let retryHost = (retryResp as? HTTPURLResponse)?.url?.host
            if retryHost == "ssoam2.ntust.edu.tw" || HTMLParser.looksLikeSSOLoginBody(retryHTML) {
                throw NTUSTScoreServiceError.redirectedToSSO
            }
            return retryHTML
        }

        return html
    }
}
