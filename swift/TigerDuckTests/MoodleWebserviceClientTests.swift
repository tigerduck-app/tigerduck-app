import Foundation
import Testing
@testable import TigerDuck

/// `MoodleWebserviceClient` against `SettingsAPIStub` on a site that does not exist, and with
/// stand-in tokens, so no request reaches Moodle.
struct MoodleWebserviceClientTests {
    private static let site = URL(string: "https://moodle-stub.invalid")!

    private struct Echo: Decodable, Sendable {
        let userid: Int
    }

    private static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        return URLSession(configuration: config)
    }

    /// The URL `call` posts `function` to; the token keeps it unique to one test.
    private static func endpoint(_ function: String, token: String) -> URL {
        URL(string: "https://moodle-stub.invalid/webservice/rest/server.php"
            + "?moodlewsrestformat=json&wsfunction=\(function)&wstoken=\(token)")!
    }

    private func call(_ function: String = "core_webservice_get_site_info", token: String, params: [(String, String)] = []) async throws -> Echo {
        try await MoodleWebserviceClient.call(
            function, params: params, token: token, as: Echo.self, session: Self.session(), siteURL: Self.site
        )
    }

    private func answer(_ status: Int, _ body: String, function: String = "core_webservice_get_site_info", token: String) {
        SettingsAPIStub.enqueue(.init(statusCode: status, body: Data(body.utf8)), for: Self.endpoint(function, token: token))
    }

    @Test("a call posts the function, the token and the form-encoded parameters, and decodes the answer")
    func callShape() async throws {
        let token = UUID().uuidString
        answer(200, #"{"userid":42,"sitename":"Moodle"}"#, function: "mod_assign_get_assignments", token: token)

        let echo = try await call("mod_assign_get_assignments", token: token, params: [("courseids[0]", "7"), ("q", "a b&c")])
        #expect(echo.userid == 42)

        let request = try #require(SettingsAPIStub.requests(for: Self.endpoint("mod_assign_get_assignments", token: token)).first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let body = SettingsAPIStub.bodyData(from: request).flatMap { String(data: $0, encoding: .utf8) }
        #expect(body == "courseids%5B0%5D=7&q=a%20b%26c")
    }

    @Test("a Moodle error body throws its case with HTTP 200 or another status")
    func errorBodies() async {
        let ok = UUID().uuidString
        answer(200, #"{"exception":"moodle_exception","errorcode":"invalidtoken"}"#, token: ok)
        await #expect(throws: MoodleWebserviceError.invalidToken) { try await call(token: ok) }

        let failed = UUID().uuidString
        answer(500, #"{"exception":"moodle_exception","errorcode":"servicenotloaded"}"#, token: failed)
        await #expect(throws: MoodleWebserviceError.webserviceDisabled) { try await call(token: failed) }
    }

    @Test("an error page, a network failure and an answer of another shape map to their cases")
    func otherFailures() async {
        let unavailable = UUID().uuidString
        answer(503, "<html>Service Unavailable</html>", token: unavailable)
        await #expect(throws: MoodleWebserviceError.httpStatus(code: 503)) { try await call(token: unavailable) }

        let offline = UUID().uuidString
        let error = await #expect(throws: MoodleWebserviceError.self) { try await call(token: offline) }
        guard case .transientNetwork = error else {
            Issue.record("expected a network error, got \(String(describing: error))")
            return
        }

        let reshaped = UUID().uuidString
        answer(200, #"{"user":"42"}"#, token: reshaped)
        let decodeError = await #expect(throws: MoodleWebserviceError.self) { try await call(token: reshaped) }
        guard case .malformedResponse = decodeError else {
            Issue.record("expected a malformed response, got \(String(describing: decodeError))")
            return
        }
    }

    // MARK: - Token

    private actor TokenLog {
        private(set) var events: [String] = []
        func record(_ event: String) { events.append(event) }
    }

    private static func tokens(stored: String?, renewed: String, log: TokenLog) -> MoodleWebserviceClient.TokenSource {
        MoodleWebserviceClient.TokenSource(
            stored: { stored },
            renew: { rejected in
                await log.record("renew \(rejected ?? "none")")
                return renewed
            }
        )
    }

    @Test("the stored token is used as it is")
    func storedTokenIsUsed() async throws {
        let log = TokenLog()
        let used = try await MoodleWebserviceClient.withToken(Self.tokens(stored: "old", renewed: "new", log: log)) { $0 }
        #expect(used == "old")
        #expect(await log.events.isEmpty)
    }

    @Test("a token Moodle calls invalid is renewed in its place, and the call runs once more")
    func invalidTokenIsRenewedOnce() async throws {
        let log = TokenLog()
        var tried: [String] = []
        let used = try await MoodleWebserviceClient.withToken(Self.tokens(stored: "old", renewed: "new", log: log)) { token in
            tried.append(token)
            if token == "old" { throw MoodleWebserviceError.invalidToken }
            return token
        }
        #expect(used == "new")
        #expect(tried == ["old", "new"])
        #expect(await log.events == ["renew old"])

        var attempts = 0
        await #expect(throws: MoodleWebserviceError.invalidToken) {
            try await MoodleWebserviceClient.withToken(Self.tokens(stored: "old", renewed: "new", log: log)) { _ -> String in
                attempts += 1
                throw MoodleWebserviceError.invalidToken
            }
        }
        #expect(attempts == 2)
    }

    @Test("another failure is not retried, and no stored token is renewed first")
    func otherFailuresAndMissingToken() async throws {
        let log = TokenLog()
        var attempts = 0
        await #expect(throws: MoodleWebserviceError.httpStatus(code: 503)) {
            try await MoodleWebserviceClient.withToken(Self.tokens(stored: "old", renewed: "new", log: log)) { _ -> String in
                attempts += 1
                throw MoodleWebserviceError.httpStatus(code: 503)
            }
        }
        #expect(attempts == 1)
        #expect(await log.events.isEmpty)

        let used = try await MoodleWebserviceClient.withToken(Self.tokens(stored: nil, renewed: "new", log: log)) { $0 }
        #expect(used == "new")
        #expect(await log.events == ["renew none"])
    }
}
