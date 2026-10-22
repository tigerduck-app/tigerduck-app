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

enum NTUSTScoreService {
    private static let scoreRootURL = URL.knownGood("https://stuinfosys.ntust.edu.tw/StuScoreQueryServ/")
    private static let scoreDisplayURL = URL.knownGood(
        "https://stuinfosys.ntust.edu.tw/StuScoreQueryServ/StuScoreQuery/DisplayAll"
    )

    static let scoreReportCacheTTL: TimeInterval = 86_400

    static func fetchScoreReport(
        session: URLSession,
        studentId: String,
        password: String,
        forceRefresh: Bool = false,
        persistGuard: (@Sendable () -> Bool)? = nil
    ) async throws -> (report: ScoreReport, cachedAt: Date) {
        if !forceRefresh,
           let cached = DataCache.shared.loadScoreReport(studentId: studentId),
           Date().timeIntervalSince(cached.cachedAt) < scoreReportCacheTTL {
            return cached
        }

        let generation = NTUSTSessionManager.shared.generation
        if !(await NTUSTSessionManager.shared.probeCookiesValid(using: session)) {
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
        let report = await Task.detached(priority: .userInitiated) {
            NTUSTScoreParser.parse(html: html)
        }.value

        if report == .empty {
            throw NTUSTScoreServiceError.parseFailed
        }

        if persistGuard?() ?? true {
            DataCache.shared.saveScoreReport(report, studentId: studentId)
        }
        return (report, Date())
    }

    static func cachedScoreReport(studentId: String) -> (report: ScoreReport, cachedAt: Date)? {
        DataCache.shared.loadScoreReport(studentId: studentId)
    }

    static func invalidateCache(studentId: String) {
        DataCache.shared.invalidateScoreReport(studentId: studentId)
    }

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
