import Foundation
import Testing
@testable import TigerDuck

@Suite("A backend request the backend refuses")
struct PushAPIRefusalTests {
    @Test("a 401 carries the access token its request sent, which its description leaves out")
    func aRefusalCarriesTheSentToken() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        let client = PushAPIClient(
            baseURLProvider: { baseURL }, session: URLSession(configuration: config), authHeaderProvider: { "Bearer B1" }
        )
        SettingsAPIStub.enqueue(
            .init(statusCode: 401, body: Data(#"{"error":"session_revoked","message":"revoked"}"#.utf8)),
            for: baseURL.appendingPathComponent("sync/revision")
        )

        let error = await #expect(throws: PushAPIError.self) { try await client.fetchRevision() }

        guard case .httpStatus(401, _, let sent)? = error else {
            Issue.record("expected a 401, got \(String(describing: error))")
            return
        }
        #expect(sent?.value == "B1")
        #expect(!String(reflecting: error as Any).contains("B1"))
    }

    @Test("a request built for no sign-in is refused a header that names one, and sent with one that names none")
    func anUnboundRequestIsRefusedASignInsHeader() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = baseURL.appendingPathComponent("sync/revision")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        let session = URLSession(configuration: config)
        let bound = BackendClient(baseURL: { baseURL }, session: session, auth: .signedIn { "Bearer B1" })
        let unbound = BackendClient(baseURL: { baseURL }, session: session, auth: .unbound { "Bearer C1" })
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data(#"{"revision":1}"#.utf8)), for: url)

        await #expect(throws: PushAPIError.self) { _ = try await bound.send(BackendRequest("GET", "sync", "revision")) }
        #expect(SettingsAPIStub.requests(for: url).isEmpty)

        _ = try await unbound.send(BackendRequest("GET", "sync", "revision"))
        #expect(SettingsAPIStub.requests(for: url).map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer C1"])
    }

    @Test("a clock_ahead whose clock is no plausible time is thrown, not sent again", arguments: [Int64.max, 0, -5])
    func anAheadRefusalWithABrokenClockIsNotResent(serverClock: Int64) async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        let client = PushAPIClient(
            baseURLProvider: { baseURL }, session: URLSession(configuration: config), authHeaderProvider: { "Bearer B1" }
        )
        let madeAt = Date(timeIntervalSince1970: 1_790_000_000)
        SettingsAPIStub.enqueue(
            .init(
                statusCode: 409, body: Data(#"{"error":"clock_ahead","message":"ahead"}"#.utf8),
                headerFields: ["X-TigerSync-Clock": String(serverClock)]
            ),
            for: baseURL.appendingPathComponent("sync/courses/client:1151:CS1001301")
                .appending(queryItems: [URLQueryItem(name: "hlc", value: String(PushAPI.clock(of: madeAt)))])
        )

        let error = await #expect(throws: PushAPIError.self) {
            try await client.deleteCourse(courseKey: "client:1151:CS1001301", madeAt: madeAt, for: testSignIn)
        }
        guard case .clockAhead(serverClock)? = error else {
            Issue.record("expected clockAhead(\(serverClock)), got \(String(describing: error))")
            return
        }
        #expect(SettingsAPIStub.requests(under: baseURL).count == 1)
    }
}
