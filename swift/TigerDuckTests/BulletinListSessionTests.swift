import Foundation
import Testing
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct BulletinListSessionTests {
    private static let onePage = Data("""
        {"items":[{"id":7,"external_id":"x7","title":"T","title_clean":null,"canonical_org":null,
        "content_tags":[],"importance":null,"summary":null,"source_url":"https://example.invalid/7",
        "posted_at":null,"is_deleted":false}],"next_cursor":null}
        """.utf8)

    @Test("a visit after the first shows the kept list without asking the server again")
    func laterVisitsReuseTheList() async {
        BulletinsViewModel.forgetListSession()
        defer { BulletinsViewModel.forgetListSession() }
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        let client = BulletinAPIClient(baseURLProvider: { baseURL }, session: URLSession(configuration: config))
        let listURL = baseURL.appendingPathComponent("bulletins")
            .appending(queryItems: [URLQueryItem(name: "limit", value: "30")])
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Self.onePage), for: listURL)

        let firstVisit = BulletinsViewModel(apiClient: client)
        await firstVisit.loadIfNeeded()
        let secondVisit = BulletinsViewModel(apiClient: client)
        await secondVisit.loadIfNeeded()

        #expect(SettingsAPIStub.requests(for: listURL).count == 1)
        #expect(secondVisit.items.contains { $0.id == 7 })
    }
}
