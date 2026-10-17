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

        func detailURL(_ id: Int) -> URL {
            baseURL.appendingPathComponent("bulletins/\(id)")
        }
    }

    private static func detail(_ id: Int) -> Data {
        Data(#"{"id":\#(id),"external_id":"x\#(id)","title":"T","title_clean":null,"canonical_org":null,"content_tags":[],"importance":null,"summary":null,"source_url":"https://example.invalid/\#(id)","posted_at":null,"is_deleted":false,"body_clean":null,"body_md":null,"raw_publisher":null}"#.utf8)
    }

    /// What a sign-out does to the cached list, for `ids` only: other tests keep their rows.
    private static func wipeCached(_ ids: Set<Int>) {
        DataCache.shared.saveBulletinSummaries(DataCache.shared.loadBulletinSummaries().filter { !ids.contains($0.id) })
    }

    private static var cachedIds: Set<Int> {
        Set(DataCache.shared.loadBulletinSummaries().map(\.id))
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
    /// The status dot's last sync is when the feed last gave its newest page, and a refresh that
    /// fails leaves it.
    @Test("the last sync is when the newest page arrived, and a failed refresh keeps it")
    func lastSyncIsTheNewestPage() async throws {
        try await withExclusiveRealDefaults {
            let saved = Defaults[.bulletinsSyncedAt]
            defer { Defaults[.bulletinsSyncedAt] = saved }
            BulletinsViewModel.forgetListSession()
            defer { BulletinsViewModel.forgetListSession() }
            let stub = Stub()
            stub.serve(Self.page([stub.id]))
            let model = BulletinsViewModel(apiClient: stub.client)
            #expect(Defaults[.bulletinsSyncedAt] == nil)

            let before = Date()
            await model.refresh()
            let syncedAt = try #require(Defaults[.bulletinsSyncedAt])
            #expect(syncedAt >= before)

            // Nothing is served for the second refresh, so it fails.
            await model.refresh()
            #expect(Defaults[.bulletinsSyncedAt] == syncedAt)
        }
    }

    @Test("a sign-out forgets the feed's last sync with the list")
    func aSignOutForgetsTheLastSync() async throws {
        try await withExclusiveRealDefaults {
            let saved = Defaults[.bulletinsSyncedAt]
            defer { Defaults[.bulletinsSyncedAt] = saved }
            defer { BulletinsViewModel.forgetListSession() }
            let stub = Stub()
            stub.serve(Self.page([stub.id]))
            await BulletinsViewModel(apiClient: stub.client).refresh()
            #expect(Defaults[.bulletinsSyncedAt] != nil)

            BulletinsViewModel.forgetListSession()

            #expect(Defaults[.bulletinsSyncedAt] == nil)
        }
    }

    private static func serveHeld(_ body: Data, for url: URL) -> SettingsAPIStub.ReplyGate {
        let gate = SettingsAPIStub.ReplyGate()
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: body, gate: gate), for: url)
        return gate
    }

    /// A sign-out after a refresh started its task, but before the task read the list epoch, leaves
    /// the fetch's epoch current and the list the departing student's
    /// (https://github.com/tigerduck-app/tigerduck-app/issues/620).
    @Test("a refresh a sign-out overtook before its fetch began keeps nothing of the departing list")
    func aSignOutBeforeTheFetchBeganKeepsNothing() async throws {
        try await withExclusiveRealDefaults {
            let saved = Defaults[.bulletinsSyncedAt]
            defer { Defaults[.bulletinsSyncedAt] = saved }
            BulletinsViewModel.forgetListSession()
            defer { BulletinsViewModel.forgetListSession() }
            let stub = Stub()
            let departed = stub.id, next = stub.id + 1
            stub.serve(Self.page([departed]))
            let model = BulletinsViewModel(apiClient: stub.client)
            await model.refresh()
            #expect(Self.cachedIds.contains(departed))

            stub.serve(Self.page([next]))
            // Queued in the refresh's own job before it runs, the sign-out comes after the refresh
            // has checked the list and before the fetch task it queues.
            let refresh = Task {
                let signOut = Task {
                    Self.wipeCached([departed])
                    BulletinsViewModel.forgetListSession()
                }
                await model.refresh()
                await signOut.value
            }
            await refresh.value

            #expect(!Self.cachedIds.contains(departed))
            #expect(!model.items.contains { $0.id == departed })
        }
    }

    /// A sign-out empties the cached list and its time; a request out when it came writes neither
    /// back for the next student.
    @Test("a refresh that lands after a sign-out writes neither the last sync nor the list")
    func aRefreshAcrossASignOutWritesNothing() async throws {
        try await withExclusiveRealDefaults {
            let saved = Defaults[.bulletinsSyncedAt]
            defer { Defaults[.bulletinsSyncedAt] = saved }
            BulletinsViewModel.forgetListSession()
            defer { BulletinsViewModel.forgetListSession() }
            let stub = Stub()
            let gate = Self.serveHeld(Self.page([stub.id]), for: stub.listURL())
            let model = BulletinsViewModel(apiClient: stub.client)
            let refresh = Task { await model.refresh() }
            try await waitUntil { SettingsAPIStub.requests(for: stub.listURL()).count == 1 }

            BulletinsViewModel.forgetListSession()
            let signedOut = Defaults[.bulletinsSyncedAt]
            gate.open()
            await refresh.value

            #expect(Defaults[.bulletinsSyncedAt] == signedOut)
            #expect(!DataCache.shared.loadBulletinSummaries().contains { $0.id == stub.id })
            // Not left loading: the list starts over for the next visit to read.
            #expect(model.loadState == .idle)
        }
    }

    @Test("a later visit's first page that lands after a sign-out writes neither the last sync nor the list")
    func aFirstPageAcrossASignOutWritesNothing() async throws {
        try await withExclusiveRealDefaults {
            let saved = Defaults[.bulletinsSyncedAt]
            defer { Defaults[.bulletinsSyncedAt] = saved }
            BulletinsViewModel.forgetListSession()
            defer { BulletinsViewModel.forgetListSession() }
            let stub = Stub()
            let (kept, newest) = (stub.id, stub.id + 1)
            stub.serve(Self.page([kept]))
            await BulletinsViewModel(apiClient: stub.client).loadIfNeeded()
            let gate = Self.serveHeld(Self.page([newest, kept]), for: stub.listURL())
            let secondVisit = BulletinsViewModel(apiClient: stub.client)
            let visit = Task { await secondVisit.loadIfNeeded() }
            try await waitUntil { SettingsAPIStub.requests(for: stub.listURL()).count == 2 }

            BulletinsViewModel.forgetListSession()
            let signedOut = Defaults[.bulletinsSyncedAt]
            gate.open()
            await visit.value

            #expect(Defaults[.bulletinsSyncedAt] == signedOut)
            #expect(!DataCache.shared.loadBulletinSummaries().contains { $0.id == newest })
        }
    }

    @Test("an older page the walk gets after a sign-out is not written")
    func aWalkAcrossASignOutWritesNothing() async throws {
        try await withExclusiveRealDefaults {
            let saved = Defaults[.bulletinsSyncedAt]
            defer { Defaults[.bulletinsSyncedAt] = saved }
            BulletinsViewModel.forgetListSession()
            defer { BulletinsViewModel.forgetListSession() }
            let stub = Stub()
            let (older, newer) = (stub.id, stub.id + 1)
            stub.serve(Self.page([newer], next: older))
            let gate = Self.serveHeld(Self.page([older]), for: stub.listURL(cursor: older))
            let model = BulletinsViewModel(apiClient: stub.client)
            await model.refresh()
            try await waitUntil { SettingsAPIStub.requests(for: stub.listURL(cursor: older)).count == 1 }

            BulletinsViewModel.forgetListSession()
            gate.open()
            await model.waitForPrefetch()

            #expect(!DataCache.shared.loadBulletinSummaries().contains { $0.id == older })
        }
    }

    @Test("an older page a scroll asks for that lands after a sign-out is not written")
    func aPageAcrossASignOutWritesNothing() async throws {
        try await withExclusiveRealDefaults {
            let saved = Defaults[.bulletinsSyncedAt]
            defer { Defaults[.bulletinsSyncedAt] = saved }
            BulletinsViewModel.forgetListSession()
            defer { BulletinsViewModel.forgetListSession() }
            let stub = Stub()
            let (older, newer) = (stub.id, stub.id + 1)
            stub.serve(Self.page([newer], next: older))
            let gate = Self.serveHeld(Self.page([older]), for: stub.listURL(cursor: older))
            let model = BulletinsViewModel(apiClient: stub.client)
            // Paused, the walk does not start, so only the scroll asks for the older page.
            model.pausePrefetch()
            await model.refresh()
            // The disk cache holds rows from earlier runs, so the end of the list is whatever is last.
            let last = try #require(model.items.last)
            let scroll = Task { await model.loadMoreIfNeeded(triggeredBy: last) }
            try await waitUntil { SettingsAPIStub.requests(for: stub.listURL(cursor: older)).count == 1 }

            BulletinsViewModel.forgetListSession()
            gate.open()
            await scroll.value

            #expect(!DataCache.shared.loadBulletinSummaries().contains { $0.id == older })
        }
    }

    /// A list on screen at a sign-out is the departing student's: the next visit, a pull or a
    /// scroll starts from the list the sign-out left, and none writes the old rows back.
    @Test("the next visit after a sign-out drops the list on screen and reads it again")
    func aVisitAfterASignOutStartsOver() async throws {
        try await withExclusiveRealDefaults {
            let saved = Defaults[.bulletinsSyncedAt]
            defer { Defaults[.bulletinsSyncedAt] = saved }
            BulletinsViewModel.forgetListSession()
            defer { BulletinsViewModel.forgetListSession() }
            let stub = Stub()
            let (kept, fresh) = (stub.id, stub.id + 1)
            stub.serve(Self.page([kept]))
            let model = BulletinsViewModel(apiClient: stub.client)
            await model.loadIfNeeded()
            BulletinsViewModel.forgetListSession()
            Self.wipeCached([kept])

            stub.serve(Self.page([fresh]))
            await model.loadIfNeeded()

            #expect(model.items.contains { $0.id == fresh })
            #expect(!model.items.contains { $0.id == kept })
            #expect(!Self.cachedIds.contains(kept))
        }
    }

    @Test("a pull after a sign-out writes only the list it reads")
    func aPullAfterASignOutStartsOver() async throws {
        try await withExclusiveRealDefaults {
            let saved = Defaults[.bulletinsSyncedAt]
            defer { Defaults[.bulletinsSyncedAt] = saved }
            BulletinsViewModel.forgetListSession()
            defer { BulletinsViewModel.forgetListSession() }
            let stub = Stub()
            let (kept, fresh) = (stub.id, stub.id + 1)
            stub.serve(Self.page([kept]))
            let model = BulletinsViewModel(apiClient: stub.client)
            await model.refresh()
            BulletinsViewModel.forgetListSession()
            Self.wipeCached([kept])

            stub.serve(Self.page([fresh]))
            await model.refresh()

            #expect(model.items.contains { $0.id == fresh })
            #expect(!model.items.contains { $0.id == kept })
            #expect(Self.cachedIds.contains(fresh))
            #expect(!Self.cachedIds.contains(kept))
        }
    }

    @Test("a scroll after a sign-out reads the list again instead of paging back through the old one")
    func aScrollAfterASignOutStartsOver() async throws {
        try await withExclusiveRealDefaults {
            let saved = Defaults[.bulletinsSyncedAt]
            defer { Defaults[.bulletinsSyncedAt] = saved }
            BulletinsViewModel.forgetListSession()
            defer { BulletinsViewModel.forgetListSession() }
            let stub = Stub()
            let (older, kept, fresh) = (stub.id, stub.id + 1, stub.id + 2)
            stub.serve(Self.page([kept], next: older))
            let model = BulletinsViewModel(apiClient: stub.client)
            model.pausePrefetch()
            await model.refresh()
            BulletinsViewModel.forgetListSession()
            Self.wipeCached([kept])

            stub.serve(Self.page([fresh]))
            let last = try #require(model.items.last)
            await model.loadMoreIfNeeded(triggeredBy: last)

            #expect(SettingsAPIStub.requests(for: stub.listURL(cursor: older)).isEmpty)
            #expect(model.items.contains { $0.id == fresh })
            #expect(!Self.cachedIds.contains(kept))
        }
    }

    @Test("a tap resolved after a sign-out goes into the list the sign-out left")
    func aTapAfterASignOutStartsOver() async throws {
        try await withExclusiveRealDefaults {
            BulletinsViewModel.forgetListSession()
            defer { BulletinsViewModel.forgetListSession() }
            let stub = Stub()
            let (kept, tapped) = (stub.id, stub.id + 1)
            stub.serve(Self.page([kept]))
            let model = BulletinsViewModel(apiClient: stub.client)
            await model.refresh()
            BulletinsViewModel.forgetListSession()
            Self.wipeCached([kept])

            SettingsAPIStub.enqueue(.init(statusCode: 200, body: Self.detail(tapped)), for: stub.detailURL(tapped))
            let summary = try await model.summary(forId: tapped)

            #expect(summary?.id == tapped)
            #expect(Self.cachedIds.contains(tapped))
            #expect(!Self.cachedIds.contains(kept))
        }
    }

    @Test("a tap that resolves after a sign-out opens and writes nothing")
    func aTapAcrossASignOutWritesNothing() async throws {
        try await withExclusiveRealDefaults {
            let saved = Defaults[.bulletinsSyncedAt]
            defer { Defaults[.bulletinsSyncedAt] = saved }
            BulletinsViewModel.forgetListSession()
            defer { BulletinsViewModel.forgetListSession() }
            let stub = Stub()
            let (tapped, fresh) = (stub.id, stub.id + 1)
            let gate = Self.serveHeld(Self.detail(tapped), for: stub.detailURL(tapped))
            let model = BulletinsViewModel(apiClient: stub.client)
            let resolve = Task { try await model.summary(forId: tapped) }
            try await waitUntil { SettingsAPIStub.requests(for: stub.detailURL(tapped)).count == 1 }

            // Signed out, then the next student's visit reads the list before the tap's answer lands.
            BulletinsViewModel.forgetListSession()
            stub.serve(Self.page([fresh]))
            await model.loadIfNeeded()
            gate.open()
            let summary = try await resolve.value

            #expect(summary?.id == tapped)
            #expect(!model.items.contains { $0.id == tapped })
            #expect(!Self.cachedIds.contains(tapped))
        }
    }

    /// "Mark all read" covers the bulletins the filters leave on screen, not every loaded one
    /// (https://github.com/tigerduck-app/tigerduck-app/issues/522).
    @Test("mark all read covers only the filtered bulletins")
    func markAllReadCoversOnlyTheFilteredBulletins() async throws {
        try await withExclusiveRealDefaults {
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
}
