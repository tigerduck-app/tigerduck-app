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
        try await MoodleWebserviceClient.call(
            "core_webservice_get_site_info", token: token, as: SiteInfo.self
        ).userid
    }

    private nonisolated struct SiteInfo: Decodable, Sendable {
        let userid: Int
    }
}
