import Foundation

/// Wraps `core_webservice_get_site_info`, memoizing the authenticated user's `userid` and the
/// web service functions the site allows, for the wstoken that asked.
///
/// Keyed by the token because a token belongs to one account: an answer that lands
/// after a sign-out or an account switch can never stand for the next account.
actor MoodleSiteInfoService {
    static let shared = MoodleSiteInfoService()

    nonisolated struct SiteInfo: Sendable, Equatable {
        let userId: Int
        /// A feature hides when a function it calls is missing here, rather than learning it from
        /// the `accessexception` the call would get.
        let functions: Set<String>
        /// `userprivateaccesskey`, which file URLs carry in place of the token. A secret, so it is
        /// never logged.
        let privateAccessKey: String?
    }

    private var cached: (token: String, info: SiteInfo)?
    private var inFlight: (token: String, task: Task<SiteInfo, Error>)?

    private init() {}

    /// The Moodle userid of the account `token` belongs to. Callers that hit
    /// `.invalidToken` refresh the token and ask again with the new one.
    func userId(token: String) async throws -> Int {
        try await siteInfo(token: token).userId
    }

    func functions(token: String) async throws -> Set<String> {
        try await siteInfo(token: token).functions
    }

    func privateAccessKey(token: String) async throws -> String? {
        try await siteInfo(token: token).privateAccessKey
    }

    private func siteInfo(token: String) async throws -> SiteInfo {
        if let cached, cached.token == token {
            return cached.info
        }
        if let inFlight, inFlight.token == token {
            return try await inFlight.task.value
        }
        let task = Task { try await Self.fetchSiteInfo(token: token) }
        inFlight = (token, task)
        defer { if inFlight?.task == task { inFlight = nil } }
        let info = try await task.value
        cached = (token, info)
        return info
    }

    /// Drop the memoized answer. Called when the Moodle token is cleared.
    func invalidateCache() {
        cached = nil
        inFlight = nil
    }

    nonisolated static func fetchSiteInfo(
        token: String,
        session: URLSession = MoodleWebserviceClient.session,
        siteURL: URL = AppConstants.moodleBaseURL
    ) async throws -> SiteInfo {
        let answer = try await MoodleWebserviceClient.call(
            "core_webservice_get_site_info", token: token, as: RawSiteInfo.self, session: session, siteURL: siteURL
        )
        return SiteInfo(
            userId: answer.userid,
            functions: Set((answer.functions ?? []).map(\.name)),
            privateAccessKey: answer.userprivateaccesskey.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    private nonisolated struct RawSiteInfo: Decodable, Sendable {
        struct Function: Decodable, Sendable {
            let name: String
        }

        let userid: Int
        let functions: [Function]?
        let userprivateaccesskey: String?
    }
}
