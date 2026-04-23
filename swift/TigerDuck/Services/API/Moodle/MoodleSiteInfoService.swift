import Foundation

/// Wraps `core_webservice_get_site_info`, memoizing the authenticated user's
/// `userid` for the lifetime of the current Moodle token.
///
/// Call `invalidateCache()` whenever the Moodle token is cleared so subsequent
/// calls fetch a fresh userid with the new token.
actor MoodleSiteInfoService {
    static let shared = MoodleSiteInfoService()

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
            guard var components = URLComponents(
                url: MoodleWebserviceClient.siteBaseURL,
                resolvingAgainstBaseURL: false
            ) else {
                throw MoodleWebserviceError.malformedResponse(detail: "invalid site_info URL base")
            }
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
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await MoodleWebserviceClient.session.data(for: request)
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
