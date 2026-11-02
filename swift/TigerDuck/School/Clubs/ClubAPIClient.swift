import Foundation

/// The public API of clubs.ntust.edu.tw, which needs no account (club-aio's `app/api/v1/public.py`).
nonisolated struct ClubAPIClient: Sendable {
    static let baseURL = URL.knownGood("https://clubs.ntust.edu.tw/api/v1/public")

    /// Checked against the host's pin set like the school's other hosts. It keeps no cookies,
    /// credentials or answers: the club stores keep those.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = SchoolSessions.requestTimeout
        config.timeoutIntervalForResource = 30
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        return SchoolSessions.pinned(config)
    }()

    /// The directory's lifetime when its `Cache-Control` names none; the server sends 300.
    static let defaultMaxAge: TimeInterval = 300
    /// A longer `max-age` is read as this, so that a wrong header cannot keep an old directory for weeks.
    static let longestMaxAge: TimeInterval = 86_400

    var baseURL = ClubAPIClient.baseURL
    var session = ClubAPIClient.session

    /// Every club, with how long the answer stays fresh; the directory carries no ETag.
    func clubs() async throws -> (body: Data, maxAge: TimeInterval) {
        var request = URLRequest(url: baseURL.appending(path: "clubs"))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (body, response) = try await send(request)
        return (body, Self.maxAge(response.value(forHTTPHeaderField: "Cache-Control")))
    }

    /// The activities from today through 13 days on; nil when unchanged since `etag`.
    func activities(etag: String?) async throws -> ETaggedBody? {
        let (body, response) = try await send(ConditionalGet(etag: etag).request(URLRequest(url: baseURL.appending(path: "activities"))))
        return ConditionalGet.answer(body, response)
    }

    static func maxAge(_ cacheControl: String?) -> TimeInterval {
        let directives = (cacheControl ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let seconds = directives.lazy.compactMap({ $0.hasPrefix("max-age=") ? Int($0.dropFirst(8)) : nil }).first,
              seconds >= 0 else { return defaultMaxAge }
        return min(TimeInterval(seconds), longestMaxAge)
    }

    /// Whether a failed fetch is worth a diagnostic: an answer this build cannot read, a status the
    /// API does not send, or an answer from another host after a redirect. A lost network, a
    /// timeout, a cancellation and the demo account's refusal, which fails like an offline
    /// request, are expected.
    static func isWorthReporting(_ error: any Error) -> Bool {
        error is DecodingError || (error as? URLError)?.code == .badServerResponse
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 304 || (200..<300).contains(http.statusCode),
              http.url?.host.map(TLSPinMatcher.hostName) == baseURL.host.map(TLSPinMatcher.hostName) else {
            throw URLError(.badServerResponse)
        }
        return (body, http)
    }
}
