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
            .init(statusCode: 401, body: Data(#"{"detail":"session_revoked"}"#.utf8)),
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
}
