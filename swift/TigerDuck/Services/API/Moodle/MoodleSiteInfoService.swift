import Foundation

/// Wraps `core_webservice_get_site_info`, memoizing the authenticated user's
/// `userid` for the wstoken that asked.
///
/// Keyed by the token because a token belongs to one account: an answer that lands
/// after a sign-out or an account switch can never stand for the next account.
actor MoodleSiteInfoService {
    static let shared = MoodleSiteInfoService()

    private var cached: (token: String, userId: Int)?
    private var inFlight: (token: String, task: Task<Int, Error>)?

    private init() {}

    /// The Moodle userid of the account `token` belongs to. Callers that hit
    /// `.invalidToken` refresh the token and ask again with the new one.
    func userId(token: String) async throws -> Int {
        if let cached, cached.token == token {
            return cached.userId
        }
        if let inFlight, inFlight.token == token {
            return try await inFlight.task.value
        }
        let task = Task { try await Self.fetchUserId(token: token) }
        inFlight = (token, task)
        defer { if inFlight?.task == task { inFlight = nil } }
        let userId = try await task.value
        cached = (token, userId)
        return userId
    }

    /// Drop the memoized userid. Called when the Moodle token is cleared.
    func invalidateCache() {
        cached = nil
        inFlight = nil
    }

    private nonisolated static func fetchUserId(token: String) async throws -> Int {
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

        guard let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MoodleWebserviceError.malformedResponse(detail: "site_info response not a JSON object")
        }
        guard let userId = info["userid"] as? Int else {
            throw MoodleWebserviceError.malformedResponse(detail: "userid missing from site_info")
        }
        return userId
    }
}
