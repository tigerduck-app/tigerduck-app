import Defaults
import Foundation
import Testing
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct BulletinListSessionTests {
    private static func page(_ ids: [Int], next: Int? = nil, orgs: [Int: String] = [:]) -> Data {
        let items = ids.map { id in
            let org = orgs[id].map { #""\#($0)""# } ?? "null"
            return #"{"id":\#(id),"external_id":"x\#(id)","title":"T","title_clean":null,"canonical_org":\#(org),"content_tags":[],"importance":null,"summary":null,"source_url":"https://example.invalid/\#(id)","posted_at":null,"is_deleted":false}"#
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

extension BulletinListSessionTests {
    /// "Mark all read" covers the bulletins the filters leave on screen, not every loaded one
    /// (https://github.com/tigerduck-app/tigerduck-app/issues/522).
    @Test("mark all read covers only the filtered bulletins")
    func markAllReadCoversOnlyTheFilteredBulletins() async throws {
        try await withExclusiveRealDefaults {
            let saved = Defaults[.savedAnnouncementDepartmentsData]
            defer { Defaults[.savedAnnouncementDepartmentsData] = saved }
            BulletinsViewModel.forgetListSession()
            defer { BulletinsViewModel.forgetListSession() }
            let stub = Stub()
            let (shown, hidden) = (stub.id, stub.id + 1)
            stub.serve(Self.page([shown, hidden], orgs: [shown: "TEST-A", hidden: "TEST-B"]))
            let model = BulletinsViewModel(apiClient: stub.client)
            await model.loadIfNeeded()
            try await waitUntil { model.items.contains { $0.id == hidden } }
            model.selectedOrgs = ["TEST-A"]
            let unread = model.unreadShown { _ in false }
            #expect(unread.contains(shown))
            #expect(!unread.contains(hidden))
        }
    }

    /// "Remember bulletin filter" brings the department filter back on the next visit, and only
    /// while it is on (https://github.com/tigerduck-app/tigerduck-app/issues/523).
    @Test("a remembered department filter comes back on the next visit")
    func aRememberedFilterComesBack() async throws {
        try await withExclusiveRealDefaults {
            let (remember, saved) = (Defaults[.rememberAnnouncementFilter], Defaults[.savedAnnouncementDepartmentsData])
            defer {
                Defaults[.rememberAnnouncementFilter] = remember
                Defaults[.savedAnnouncementDepartmentsData] = saved
            }
            let client = Stub().client
            Defaults[.rememberAnnouncementFilter] = true
            BulletinsViewModel(apiClient: client).selectedOrgs = ["TEST-A"]
            #expect(BulletinsViewModel(apiClient: client).selectedOrgs == ["TEST-A"])
            Defaults[.rememberAnnouncementFilter] = false
            #expect(BulletinsViewModel(apiClient: client).selectedOrgs.isEmpty)
        }
    }
}
