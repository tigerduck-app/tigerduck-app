import Foundation
import Testing
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct BulletinListSessionTests {
    private static func page(_ ids: [Int], next: Int? = nil) -> Data {
        let items = ids.map { id in
            #"{"id":\#(id),"external_id":"x\#(id)","title":"T","title_clean":null,"canonical_org":null,"content_tags":[],"importance":null,"summary":null,"source_url":"https://example.invalid/\#(id)","posted_at":null,"is_deleted":false}"#
        }
        let cursor = next.map(String.init) ?? "null"
        return Data(#"{"items":[\#(items.joined(separator: ","))],"next_cursor":\#(cursor)}"#.utf8)
    }

    private struct Stub {
        let client: BulletinAPIClient
        let baseURL: URL
        /// The view model starts from the disk cache, which keeps rows from earlier runs and the
        /// app, so each test's ids are new.
        let id = Int.random(in: 1_000_000_000...2_000_000_000)

        init() {
            baseURL = SettingsAPIStub.uniqueBaseURL()
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [SettingsAPIStub.self]
            let baseURL = baseURL
            client = BulletinAPIClient(baseURLProvider: { baseURL }, session: URLSession(configuration: config))
        }

        func listURL(cursor: Int? = nil) -> URL {
            var query = [URLQueryItem(name: "limit", value: "30")]
            if let cursor { query.append(URLQueryItem(name: "cursor", value: String(cursor))) }
            return baseURL.appendingPathComponent("bulletins").appending(queryItems: query)
        }

        func serve(_ body: Data, cursor: Int? = nil) {
            SettingsAPIStub.enqueue(.init(statusCode: 200, body: body), for: listURL(cursor: cursor))
        }
    }

    @Test("a later visit asks for the first page and keeps the pages the first visit walked")
    func laterVisitsAskForTheFirstPageOnly() async throws {
        BulletinsViewModel.forgetListSession()
        defer { BulletinsViewModel.forgetListSession() }
        let stub = Stub()
        let (older, newer, newest) = (stub.id, stub.id + 1, stub.id + 2)
        stub.serve(Self.page([newer], next: older))
        stub.serve(Self.page([older]), cursor: older)
        stub.serve(Self.page([newest, newer], next: older))

        let firstVisit = BulletinsViewModel(apiClient: stub.client)
        await firstVisit.loadIfNeeded()
        try await waitUntil { firstVisit.items.contains { $0.id == older } }
        let secondVisit = BulletinsViewModel(apiClient: stub.client)
        await secondVisit.loadIfNeeded()

        #expect(SettingsAPIStub.requests(for: stub.listURL()).count == 2)
        #expect(SettingsAPIStub.requests(for: stub.listURL(cursor: older)).count == 1)
        #expect(secondVisit.items.contains { $0.id == newest })
    }

    @Test("a first page with nothing the kept list has walks the pages behind it")
    func aGapWalksOn() async throws {
        BulletinsViewModel.forgetListSession()
        defer { BulletinsViewModel.forgetListSession() }
        let stub = Stub()
        let (kept, gap, newest) = (stub.id, stub.id + 1, stub.id + 2)
        stub.serve(Self.page([kept]))
        stub.serve(Self.page([newest], next: gap))
        stub.serve(Self.page([gap]), cursor: gap)

        let firstVisit = BulletinsViewModel(apiClient: stub.client)
        await firstVisit.loadIfNeeded()
        let secondVisit = BulletinsViewModel(apiClient: stub.client)
        await secondVisit.loadIfNeeded()

        try await waitUntil { secondVisit.items.contains { $0.id == gap } }
    }
}
