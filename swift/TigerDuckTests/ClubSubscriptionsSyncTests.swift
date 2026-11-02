import Defaults
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct ClubSubscriptionsSyncTests {
    typealias Document = ClubSubscriptionsDocument
    typealias Fixtures = NotificationSettingsFixtures

    static func documentURL(_ baseURL: URL) -> URL {
        baseURL.appendingPathComponent("settings/club_subscriptions")
    }

    static func subscribed(_ ids: [Int], from minute: Int = 1) -> Document {
        var document = Document()
        for (offset, id) in ids.enumerated() {
            document.subscribe(id, defaultColor: 0xD35400, at: ClubSubscriptionsDocumentTests.at(minute + offset))
        }
        return document
    }

    static func object(_ document: Document) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: document.json()) as? [String: Any])
    }

    static func sent(_ request: URLRequest) throws -> Document {
        Document(json: try JSONSerialization.data(withJSONObject: try Fixtures.sentDocument(request)))
    }

    @Test("a first push creates the document from the device's copy")
    func firstPushCreates() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        SettingsAPIStub.enqueue(Fixtures.notFound(), for: url)
        SettingsAPIStub.enqueue(try Fixtures.written(revision: 1), for: url)
        let local = Self.subscribed([93])

        let synced = try await ClubSubscriptionsSync.sync(
            local: local, client: SettingsAPIStub.makeClient(baseURL: baseURL), stored: nil, mayWrite: { true }
        )

        #expect(synced == local)
        let requests = SettingsAPIStub.requests(for: url)
        try #require(requests.map(\.httpMethod) == ["GET", "PUT"])
        #expect(try Fixtures.sentEnvelope(requests[1])["base_revision"] is NSNull)
        #expect(try Self.sent(requests[1]) == local)
    }

    @Test("keys this build does not know survive the write, at the top and inside a club")
    func unknownKeysSurvive() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        var server = try Self.object(Self.subscribed([33]))
        var clubs = try #require(server["clubs"] as? [String: Any])
        var club = try #require(clubs["33"] as? [String: Any])
        club["notify"] = true
        clubs["33"] = club
        server["clubs"] = clubs
        server["future"] = ["x": 1]
        SettingsAPIStub.enqueue(try Fixtures.found(server, revision: 3), for: url)
        SettingsAPIStub.enqueue(try Fixtures.written(revision: 4), for: url)
        var local = Self.subscribed([33])
        local.subscribe(93, defaultColor: 0xD35400, at: ClubSubscriptionsDocumentTests.at(5))

        _ = try await ClubSubscriptionsSync.sync(
            local: local, client: SettingsAPIStub.makeClient(baseURL: baseURL), stored: nil, mayWrite: { true }
        )

        let put = try #require(SettingsAPIStub.requests(for: url).last)
        let written = try Fixtures.sentDocument(put)
        #expect((written["future"] as? [String: Any])?["x"] as? Int == 1)
        #expect(((written["clubs"] as? [String: Any])?["33"] as? [String: Any])?["notify"] as? Bool == true)
        #expect(try Fixtures.sentEnvelope(put)["base_revision"] as? Int == 3)
        #expect(try Self.sent(put).subscribedIDs == [33, 93])
    }

    @Test("a document the server already holds is not written again, and the device takes the server's newer values")
    func nothingToWrite() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let server = Self.subscribed([41, 93], from: 10)
        SettingsAPIStub.enqueue(try Fixtures.found(try Self.object(server), revision: 7), for: url)

        let synced = try await ClubSubscriptionsSync.sync(
            local: Self.subscribed([93]), client: SettingsAPIStub.makeClient(baseURL: baseURL), stored: nil, mayWrite: { true }
        )

        #expect(synced == server)
        #expect(SettingsAPIStub.requests(for: url).map(\.httpMethod) == ["GET"])
    }

    @Test("a 409 is merged once more with the newer copy it carries, and a second 409 gives up")
    func conflicts() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        SettingsAPIStub.enqueue(try Fixtures.found([:], revision: 3), for: url)
        SettingsAPIStub.enqueue(try Fixtures.conflict(try Self.object(Self.subscribed([41], from: 9)), revision: 4), for: url)
        SettingsAPIStub.enqueue(try Fixtures.written(revision: 5), for: url)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)

        let synced = try await ClubSubscriptionsSync.sync(local: Self.subscribed([93]), client: client, stored: nil, mayWrite: { true })

        let puts = SettingsAPIStub.requests(for: url).filter { $0.httpMethod == "PUT" }
        try #require(puts.count == 2)
        #expect(try Fixtures.sentEnvelope(puts[1])["base_revision"] as? Int == 4)
        #expect(try Self.sent(puts[1]) == synced)
        #expect(synced?.subscribedIDs == [41, 93])

        let again = SettingsAPIStub.uniqueBaseURL()
        SettingsAPIStub.enqueue(try Fixtures.conflict([:], revision: 1), for: Self.documentURL(again))
        SettingsAPIStub.enqueue(try Fixtures.conflict([:], revision: 2), for: Self.documentURL(again))
        await #expect(throws: ClubSubscriptionsSync.SyncError.conflictNotResolved) {
            try await ClubSubscriptionsSync.sync(
                local: Self.subscribed([93]), client: SettingsAPIStub.makeClient(baseURL: again),
                stored: .neverWritten, mayWrite: { true }
            )
        }
    }

    @Test("a snapshot's copy is used without a read, and nothing is written once writes are no longer allowed")
    func snapshotAndMayWrite() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)

        let held = try await ClubSubscriptionsSync.sync(local: Self.subscribed([93]), client: client, stored: .neverWritten, mayWrite: { false })

        #expect(held == nil)
        #expect(SettingsAPIStub.requests(for: url).isEmpty)
    }

    @Test("a snapshot older than one of the device's own runs is read again, and a run that lands clears the unsent mark")
    func syncerSnapshots() async throws {
        try await withExclusiveRealDefaults {
            Defaults.reset(.clubSubscriptions, .clubSubscriptionsPushPending)
            let syncWasOn = Defaults[.cloudSyncEnabled]
            Defaults[.cloudSyncEnabled, for: testSignIn] = true
            defer {
                Defaults.reset(.clubSubscriptions, .clubSubscriptionsPushPending)
                Defaults[.cloudSyncEnabled, for: testSignIn] = syncWasOn
            }
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let url = Self.documentURL(baseURL)
            let subscriptions = ClubSubscriptions()
            let syncer = ClubSubscriptionsSyncer(subscriptions: subscriptions, startingSignIn: { testSignIn }) { _ in
                SettingsAPIStub.makeClient(baseURL: baseURL)
            }
            subscriptions.subscribe(93, for: testSignIn)
            SettingsAPIStub.enqueue(try Fixtures.written(revision: 1), for: url)

            #expect(await syncer.sync(snapshot: .neverWritten, runsBeforeSnapshot: 0, for: testSignIn) == .synced)
            #expect(!subscriptions.hasUnsentChanges)

            SettingsAPIStub.enqueue(try Fixtures.found(try Self.object(subscriptions.document), revision: 1), for: url)
            #expect(await syncer.sync(snapshot: .neverWritten, runsBeforeSnapshot: 0, for: testSignIn) == .synced)
            #expect(SettingsAPIStub.requests(for: url).map(\.httpMethod) == ["PUT", "GET"])
            #expect(subscriptions.subscribedIDs == [93])
        }
    }

    @Test("a club edit whose write failed is sent again on a poll that finds no new revision")
    func pollWithoutChangesRetries() async throws {
        try await withExclusiveRealDefaults {
            Defaults.reset(.clubSubscriptions, .clubSubscriptionsPushPending)
            let syncWasOn = Defaults[.cloudSyncEnabled]
            Defaults[.cloudSyncEnabled, for: testSignIn] = true
            defer {
                Defaults.reset(.clubSubscriptions, .clubSubscriptionsPushPending)
                Defaults[.cloudSyncEnabled, for: testSignIn] = syncWasOn
            }
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let url = Self.documentURL(baseURL)
            let subscriptions = ClubSubscriptions()
            let syncer = ClubSubscriptionsSyncer(subscriptions: subscriptions, startingSignIn: { testSignIn }) { _ in
                SettingsAPIStub.makeClient(baseURL: baseURL)
            }
            subscriptions.subscribe(93, for: testSignIn)
            SettingsAPIStub.enqueue(Fixtures.notFound(), for: url)
            SettingsAPIStub.enqueue(.init(statusCode: 500, body: Data()), for: url)
            #expect(await syncer.sync() == .failed)
            SettingsAPIStub.enqueue(Fixtures.notFound(), for: url)
            SettingsAPIStub.enqueue(try Fixtures.written(revision: 1), for: url)

            let outcome = ChangeFeedPull.noNewRevision(watermark: 5, notePull: {}, retryUnsentSettings: { syncer.retryUnacknowledged() })

            #expect(outcome == .unchanged)
            try await waitUntil(timeout: .seconds(5)) { !subscriptions.hasUnsentChanges }
            #expect(SettingsAPIStub.requests(for: url).map(\.httpMethod) == ["GET", "PUT", "GET", "PUT"])
        }
    }

    @Test("a full sync's club run whose read failed, with nothing unsent, is owed and run again on the next poll")
    func failedReadIsOwed() async throws {
        try await withExclusiveRealDefaults {
            Defaults.reset(.clubSubscriptions, .clubSubscriptionsPushPending)
            let syncWasOn = Defaults[.cloudSyncEnabled]
            Defaults[.cloudSyncEnabled, for: testSignIn] = true
            defer {
                Defaults.reset(.clubSubscriptions, .clubSubscriptionsPushPending)
                Defaults[.cloudSyncEnabled, for: testSignIn] = syncWasOn
            }
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let url = Self.documentURL(baseURL)
            let subscriptions = ClubSubscriptions()
            let syncer = ClubSubscriptionsSyncer(subscriptions: subscriptions, startingSignIn: { testSignIn }) { _ in
                SettingsAPIStub.makeClient(baseURL: baseURL)
            }
            SettingsAPIStub.enqueue(.init(statusCode: 500, body: Data()), for: url)

            #expect(await syncer.sync(snapshot: .neverWritten, runsBeforeSnapshot: syncer.finishedRuns + 1, for: testSignIn) == .failed)
            #expect(!subscriptions.hasUnsentChanges)
            #expect(syncer.owesRun)

            SettingsAPIStub.enqueue(try Fixtures.found(try Self.object(Self.subscribed([41])), revision: 2), for: url)
            #expect(ChangeFeedPull.noNewRevision(watermark: 5, notePull: {}, retryUnsentSettings: { syncer.retryUnacknowledged() }) == .unchanged)

            try await waitUntil(timeout: .seconds(5)) { subscriptions.subscribedIDs == [41] }
            #expect(!syncer.owesRun)
            #expect(SettingsAPIStub.requests(for: url).map(\.httpMethod) == ["GET", "GET"])
        }
    }

    @Test("a snapshot read for an earlier sign-in is dropped, and the run reads the server's copy for its own")
    func snapshotOfAnotherSignIn() async throws {
        try await withExclusiveRealDefaults {
            Defaults.reset(.clubSubscriptions, .clubSubscriptionsPushPending)
            let syncWasOn = Defaults[.cloudSyncEnabled]
            Defaults[.cloudSyncEnabled, for: testSignIn] = true
            defer {
                Defaults.reset(.clubSubscriptions, .clubSubscriptionsPushPending)
                Defaults[.cloudSyncEnabled, for: testSignIn] = syncWasOn
            }
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let url = Self.documentURL(baseURL)
            let subscriptions = ClubSubscriptions()
            let syncer = ClubSubscriptionsSyncer(subscriptions: subscriptions, startingSignIn: { testSignIn }) { _ in
                SettingsAPIStub.makeClient(baseURL: baseURL)
            }
            subscriptions.subscribe(93, for: testSignIn)
            SettingsAPIStub.enqueue(try Fixtures.found(try Self.object(Self.subscribed([41], from: 9)), revision: 2), for: url)
            SettingsAPIStub.enqueue(try Fixtures.written(revision: 3), for: url)

            #expect(await syncer.sync(snapshot: .neverWritten, runsBeforeSnapshot: 0, for: endedTestSignIn) == .synced)

            let requests = SettingsAPIStub.requests(for: url)
            try #require(requests.map(\.httpMethod) == ["GET", "PUT"])
            #expect(try Fixtures.sentEnvelope(requests[1])["base_revision"] as? Int == 2)
            #expect(Set(subscriptions.subscribedIDs) == [41, 93])
        }
    }

    @Test(
        "a sign-out, or cloud sync switched off, while the write is out leaves the device's copy and its unsent mark alone",
        arguments: [true, false]
    )
    func endedMidWrite(bySignOut: Bool) async throws {
        try await withExclusiveRealDefaults {
            Defaults.reset(.clubSubscriptions, .clubSubscriptionsPushPending)
            let syncWasOn = Defaults[.cloudSyncEnabled]
            Defaults[.cloudSyncEnabled, for: testSignIn] = true
            defer {
                Defaults.reset(.clubSubscriptions, .clubSubscriptionsPushPending)
                Defaults[.cloudSyncEnabled, for: testSignIn] = syncWasOn
            }
            let account = TestSignIn()
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let url = Self.documentURL(baseURL)
            let subscriptions = ClubSubscriptions()
            let syncer = ClubSubscriptionsSyncer(subscriptions: subscriptions, startingSignIn: { account.signIn }) { _ in
                SettingsAPIStub.makeClient(baseURL: baseURL)
            }
            subscriptions.subscribe(93, for: account.signIn)
            let before = subscriptions.document
            let gate = SettingsAPIStub.ReplyGate()
            SettingsAPIStub.enqueue(Fixtures.notFound(), for: url)
            var written = try Fixtures.written(revision: 1)
            written.gate = gate
            SettingsAPIStub.enqueue(written, for: url)

            let run = Task { await syncer.sync() }
            try await waitUntil { SettingsAPIStub.requests(for: url).count == 2 }
            if bySignOut { account.signOut() } else { Defaults[.cloudSyncEnabled, for: testSignIn] = false }
            gate.open()

            #expect(await run.value == .skipped)
            #expect(subscriptions.document == before)
            #expect(subscriptions.hasUnsentChanges)
        }
    }
}
