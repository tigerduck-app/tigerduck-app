import Foundation

/// Wraps `core_webservice_get_site_info`, memoizing the authenticated user's
/// `userid` for the lifetime of the current Moodle token.
///
/// Call `invalidateCache()` whenever the Moodle token is cleared so subsequent
/// calls fetch a fresh userid with the new token.
actor MoodleSiteInfoService {
    static let shared = MoodleSiteInfoService()

    private static let siteBaseURL = URL(string: "https://moodle2.ntust.edu.tw")!
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

    private var cachedUserId: Int?

    private init() {}

    /// Returns the authenticated user's Moodle userid.
    /// Cached for the lifetime of the current wstoken; call `invalidateCache()` on token change.
    func userId() async throws -> Int {
        if let cachedUserId {
            return cachedUserId
        }

        let info = try await fetchSiteInfo()
        guard let userId = info["userid"] as? Int else {
            throw MoodleWebserviceError.malformedResponse(detail: "userid missing from site_info")
        }

        cachedUserId = userId
        return userId
    }

    /// Reset the cached userid. Must be called when the Moodle token is cleared.
    func invalidateCache() {
        cachedUserId = nil
    }

    private func fetchSiteInfo() async throws -> [String: Any] {
        let tokenService = MoodleTokenService.shared

        func requestSiteInfo(using token: String) async throws -> [String: Any] {
            var components = URLComponents(url: Self.siteBaseURL, resolvingAgainstBaseURL: false)!
            components.path = "/webservice/rest/server.php"
            components.queryItems = [
                URLQueryItem(name: "moodlewsrestformat", value: "json"),
                URLQueryItem(name: "wsfunction", value: "core_webservice_get_site_info"),
                URLQueryItem(name: "wstoken", value: token),
            ]

            guard let url = components.url else {
                throw MoodleWebserviceError.malformedResponse(detail: "invalid site_info URL")
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"

            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await Self.webserviceSession.data(for: request)
            } catch let urlError as URLError {
                throw MoodleWebserviceError.transientNetwork(underlying: urlError.localizedDescription)
            }

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw MoodleWebserviceError.httpStatus(code: (response as? HTTPURLResponse)?.statusCode ?? 0)
            }

            if let moodleError = MoodleWebserviceError.from(jsonData: data) {
                throw moodleError
            }

            guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MoodleWebserviceError.malformedResponse(detail: "site_info response not a JSON object")
            }

            return dict
        }

        if let currentToken = await tokenService.currentToken() {
            do {
                return try await requestSiteInfo(using: currentToken)
            } catch MoodleWebserviceError.invalidToken {
                await tokenService.clearToken()
                let refreshedToken = try await tokenService.refreshTokenIfNeeded()
                return try await requestSiteInfo(using: refreshedToken)
            }
        }

        let refreshedToken = try await tokenService.refreshTokenIfNeeded()
        return try await requestSiteInfo(using: refreshedToken)
    }
}
