import Foundation
import Testing
@testable import TigerDuck

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

    private static func endpoint(_ function: String, token: String) -> URL {
        URL(string: "https://moodle-stub.invalid/webservice/rest/server.php"
            + "?moodlewsrestformat=json&wsfunction=\(function)&wstoken=\(token)")!
    }

    private func call(_ function: String = "core_webservice_get_site_info", token: String, params: [(String, String)] = []) async throws -> Echo {
        try await MoodleWebserviceClient.call(
            function, params: params, token: token, as: Echo.self, session: Self.session(), siteURL: Self.site
        )
    }

    private func answer(
        _ status: Int, _ body: String, headers: [String: String] = [:],
        function: String = "core_webservice_get_site_info", token: String
    ) {
        SettingsAPIStub.enqueue(
            .init(statusCode: status, body: Data(body.utf8), headerFields: headers), for: Self.endpoint(function, token: token)
        )
    }

    @Test("a call names the function in its URL, posts the token first in the form, and decodes the answer")
    func callShape() async throws {
        let token = UUID().uuidString
        answer(200, #"{"userid":42,"sitename":"Moodle"}"#, function: "mod_assign_get_assignments", token: token)

        let echo = try await call("mod_assign_get_assignments", token: token, params: [("courseids[0]", "7"), ("q", "a b&c")])
        #expect(echo.userid == 42)

        let request = try #require(SettingsAPIStub.requests(for: Self.endpoint("mod_assign_get_assignments", token: token)).first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.query == "moodlewsrestformat=json&wsfunction=mod_assign_get_assignments")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let body = SettingsAPIStub.bodyData(from: request).flatMap { String(data: $0, encoding: .utf8) }
        #expect(body == "wstoken=\(token)&courseids%5B0%5D=7&q=a%20b%26c")
    }

    @Test("a Moodle error body throws its case with HTTP 200 or another status, even a 503 with Retry-After")
    func errorBodies() async {
        let ok = UUID().uuidString
        answer(200, #"{"exception":"moodle_exception","errorcode":"invalidtoken"}"#, token: ok)
        await #expect(throws: MoodleWebserviceError.invalidToken) { try await call(token: ok) }

        let failed = UUID().uuidString
        answer(500, #"{"exception":"moodle_exception","errorcode":"servicenotloaded"}"#, token: failed)
        await #expect(throws: MoodleWebserviceError.webserviceDisabled) { try await call(token: failed) }

        let busy = UUID().uuidString
        answer(503, #"{"exception":"moodle_exception","errorcode":"invalidtoken"}"#, headers: ["Retry-After": "300"], token: busy)
        await #expect(throws: MoodleWebserviceError.invalidToken) { try await call(token: busy) }
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

    @Test("a 503 page with Retry-After is Moodle's upgrade maintenance", arguments: ["Retry-After", "retry-after"])
    func cliMaintenance(header: String) async {
        let token = UUID().uuidString
        answer(
            503, "<html>Moodle under maintenance</html>",
            headers: [header: "300", "Content-Type": "text/html; charset=utf-8"], token: token
        )
        await #expect(throws: MoodleWebserviceError.siteMaintenance) { try await call(token: token) }
    }

    @Test("the assignment fetch asks only for courses the user can submit to")
    func assignmentsNeedTheSubmitCapability() async throws {
        let token = UUID().uuidString
        answer(200, #"{"courses":[],"warnings":[]}"#, function: "mod_assign_get_assignments", token: token)

        let records = try await MoodleAssignmentService.fetchAssignments(
            courseIds: [7, 9],
            tokens: .init(stored: { token }, renew: { _ in token }),
            session: Self.session(),
            siteURL: Self.site
        )
        #expect(records.isEmpty)

        let request = try #require(SettingsAPIStub.requests(for: Self.endpoint("mod_assign_get_assignments", token: token)).first)
        let body = SettingsAPIStub.bodyData(from: request).flatMap { String(data: $0, encoding: .utf8) }
        #expect(body == "wstoken=\(token)&courseids%5B0%5D=7&courseids%5B1%5D=9&capabilities%5B0%5D=mod%2Fassign%3Asubmit")
    }

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

    @Test("an access error is tried once more with the same token and renews nothing")
    func accessErrorIsNotRenewed() async {
        let log = TokenLog()
        var tried: [String] = []
        await #expect(throws: MoodleWebserviceError.accessDenied) {
            try await MoodleWebserviceClient.withToken(Self.tokens(stored: "old", renewed: "new", log: log)) { token -> String in
                tried.append(token)
                throw MoodleWebserviceError.accessDenied
            }
        }
        #expect(tried == ["old", "old"])
        #expect(await log.events.isEmpty)
    }

    @Test("an expired token's access error renews the token once Moodle calls it invalid")
    func expiredTokenIsRenewed() async throws {
        let log = TokenLog()
        var answers: [MoodleWebserviceError] = [.accessDenied, .invalidToken]
        let used = try await MoodleWebserviceClient.withToken(Self.tokens(stored: "old", renewed: "new", log: log)) { token in
            if !answers.isEmpty { throw answers.removeFirst() }
            return token
        }
        #expect(used == "new")
        #expect(await log.events == ["renew old"])
    }

    @Test("an access error from the renewed token is final")
    func accessErrorAfterRenewal() async {
        let log = TokenLog()
        var answers: [MoodleWebserviceError] = [.invalidToken, .accessDenied]
        await #expect(throws: MoodleWebserviceError.accessDenied) {
            try await MoodleWebserviceClient.withToken(Self.tokens(stored: "old", renewed: "new", log: log)) { _ -> String in
                throw answers.removeFirst()
            }
        }
        #expect(answers.isEmpty)
        #expect(await log.events == ["renew old"])
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
