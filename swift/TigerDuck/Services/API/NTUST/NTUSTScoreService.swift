import Foundation

enum NTUSTScoreServiceError: LocalizedError {
    case notAuthenticated
    case redirectedToSSO
    case invalidResponse
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return String(localized: "common_not_signed_in")
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
    private static let scoreRootURL = URL.knownGood("https://stuinfosys.ntust.edu.tw/StuScoreQueryServ/")
    private static let scoreDisplayURL = URL.knownGood(
        "https://stuinfosys.ntust.edu.tw/StuScoreQueryServ/StuScoreQuery/DisplayAll"
    )

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
        forceRefresh: Bool = false,
        persistGuard: (@Sendable () -> Bool)? = nil
    ) async throws -> ScoreReport {
        if !forceRefresh,
           let cached = DataCache.shared.loadScoreReport(studentId: studentId),
           Date().timeIntervalSince(cached.cachedAt) < scoreReportCacheTTL {
            return cached.report
        }

        let generation = NTUSTSessionManager.shared.generation
        if !(await NTUSTSessionManager.shared.probeCookiesValid()) {
            let loggedIn = try await SSOLoginService.ensureServiceLogin(
                session: session,
                serviceURL: scoreRootURL,
                studentId: studentId,
                password: password,
                generation: generation
            )
            guard loggedIn else { throw NTUSTScoreServiceError.notAuthenticated }
        }

        let html = try await fetchHTML(
            session: session, studentId: studentId, password: password, generation: generation
        )
        // Parse off the main actor — SwiftSoup over a full transcript is
        // tens of milliseconds on an older phone.
        let report = await Task.detached(priority: .userInitiated) {
            NTUSTScoreParser.parse(html: html)
        }.value

        // Defensive: a successful fetch that parses to a fully empty report
        // usually means the HTML was actually the SSO page disguised as a
        // 200 — avoid poisoning the cache with that.
        if report == .empty {
            throw NTUSTScoreServiceError.parseFailed
        }

        // `persistGuard` runs after the long network hop, so a logout or account swap
        // between fetch and persist never leaves the previous account's score report in
        // the cache for the next account to inherit.
        if persistGuard?() ?? true {
            DataCache.shared.saveScoreReport(report, studentId: studentId)
        }
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
        password: String,
        generation: Int
    ) async throws -> String {
        let (data, response) = try await session.data(from: scoreDisplayURL)
        guard let html = String(data: data, encoding: .utf8) else {
            throw NTUSTScoreServiceError.invalidResponse
        }

        // Bounced to another host (ssoam2, or the portal a lapsed service session is sent to):
        // re-login silently and retry once. The body check catches an SSO login form served
        // inline with HTTP 200, as stuinfosys has done in Shibboleth maintenance.
        let landedElsewhere = (response as? HTTPURLResponse)?.url?.host != scoreDisplayURL.host
        let bodyIsSSO = HTMLParser.looksLikeSSOLoginBody(html)
        if landedElsewhere || bodyIsSSO {
            NTUSTSessionManager.shared.dropServiceCookies(for: scoreDisplayURL)
            let loggedIn = try await SSOLoginService.ensureServiceLogin(
                session: session,
                serviceURL: scoreRootURL,
                studentId: studentId,
                password: password,
                generation: generation
            )
            guard loggedIn else { throw NTUSTScoreServiceError.notAuthenticated }

            let (retryData, retryResp) = try await session.data(from: scoreDisplayURL)
            guard let retryHTML = String(data: retryData, encoding: .utf8) else {
                throw NTUSTScoreServiceError.invalidResponse
            }
            let retryHost = (retryResp as? HTTPURLResponse)?.url?.host
            if retryHost != scoreDisplayURL.host || HTMLParser.looksLikeSSOLoginBody(retryHTML) {
                throw NTUSTScoreServiceError.redirectedToSSO
            }
            return retryHTML
        }

        return html
    }
}
