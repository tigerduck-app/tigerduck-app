import Foundation
import Testing
@testable import TigerDuck

struct ChangeFeedPlanTests {
    private static func page(
        _ changes: [(revision: Int, type: String)],
        current: Int? = nil,
        returnedUntil: Int? = nil,
        hasMore: Bool = false
    ) -> PushAPI.SyncChangesPage {
        let current = current ?? changes.last?.revision ?? 0
        return PushAPI.SyncChangesPage(
            currentRevision: current,
            returnedUntilRevision: returnedUntil ?? current,
            hasMore: hasMore,
            changes: changes.map { .init(revision: $0.revision, entityType: $0.type) }
        )
    }

    @Test("Assignment and bulletin changes only move the watermark")
    func serverBookkeepingOnlyAdvances() {
        let page = Self.page([(11, "assignment"), (12, "bulletin_state"), (14, "assignment")])
        #expect(ChangeFeedPlan(page, since: 10) == .advance(to: 14))
    }

    @Test("A notification settings change gets the reconcile, beside assignment changes or not")
    func settingsChangesReconcile() {
        #expect(ChangeFeedPlan(Self.page([(11, "settings_document")]), since: 10)
            == .reconcileSettings(thenAdvanceTo: 11))
        #expect(ChangeFeedPlan(Self.page([(11, "assignment"), (12, "settings_document")]), since: 10)
            == .reconcileSettings(thenAdvanceTo: 12))
    }

    @Test(
        "A change a full sync applies, or a type this build does not know, takes the full sync",
        arguments: [
            "assignment_override", "course", "course_override", "course_skipped_date",
            "holiday_override", "calendar_note",
        ]
    )
    func otherChangesTakeTheFullSync(entityType: String) {
        let page = Self.page([(11, "assignment"), (12, entityType), (13, "settings_document")])
        #expect(ChangeFeedPlan(page, since: 10) == .fullSync)
    }

    @Test("A page that may not hold every change up to the current revision takes the full sync")
    func partialPagesTakeTheFullSync() {
        let more = Self.page([(11, "assignment")], current: 20, returnedUntil: 11, hasMore: true)
        #expect(ChangeFeedPlan(more, since: 10) == .fullSync)
        #expect(ChangeFeedPlan(Self.page([(11, "assignment")], current: 12), since: 10) == .fullSync)
        #expect(ChangeFeedPlan(Self.page([], current: 12), since: 10) == .fullSync)
        #expect(ChangeFeedPlan(Self.page([(11, "assignment")], returnedUntil: 10), since: 10) == .fullSync)
    }

    @Test("A page that answers another read, as after a server reset, takes the full sync")
    func pagesFromBeforeTheWatermarkTakeTheFullSync() {
        #expect(ChangeFeedPlan(Self.page([(9, "assignment"), (11, "assignment")]), since: 10) == .fullSync)
        #expect(ChangeFeedPlan(Self.page([(8, "assignment")]), since: 10) == .fullSync)
    }

    @Test("No page, from a failed read or compacted changes, takes the full sync")
    func noPageTakesTheFullSync() {
        #expect(ChangeFeedPlan(nil, since: 10) == .fullSync)
    }
}

struct ChangeFeedWatermarkTests {
    @Test("A read that nothing overtook may move the watermark")
    func readNothingOvertookMayAdvance() {
        #expect(AppState.feedMayAdvanceRevision(
            readAfter: 10, watermark: 10, startedIn: 4, current: 4, cloudSyncEnabled: true))
    }

    @Test("A sign-out, a full sync that set its own watermark, or sync switched off keeps it")
    func overtakenReadKeepsTheWatermark() {
        #expect(!AppState.feedMayAdvanceRevision(
            readAfter: 10, watermark: 0, startedIn: 4, current: 5, cloudSyncEnabled: true))
        #expect(!AppState.feedMayAdvanceRevision(
            readAfter: 10, watermark: 10, startedIn: 4, current: 6, cloudSyncEnabled: true))
        #expect(!AppState.feedMayAdvanceRevision(
            readAfter: 10, watermark: 13, startedIn: 4, current: 4, cloudSyncEnabled: true))
        #expect(!AppState.feedMayAdvanceRevision(
            readAfter: 10, watermark: 10, startedIn: 4, current: 4, cloudSyncEnabled: false))
    }
}

/// Each client gets an `APIVersionGate` of its own: the shared one latches for the process, and
/// `SettingsDocumentClientTests` owns it.
@MainActor
struct ChangeFeedClientTests {
    @MainActor
    private struct Backend {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let gate = APIVersionGate()

        func feedURL(since: Int) -> URL {
            baseURL.appendingPathComponent("sync")
                .appending(queryItems: [URLQueryItem(name: "since_revision", value: String(since))])
        }

        func answer(_ url: URL, status: Int, _ body: String) {
            SettingsAPIStub.enqueue(.init(statusCode: status, body: Data(body.utf8)), for: url)
        }

        func makeClient() -> PushAPIClient {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [SettingsAPIStub.self]
            return PushAPIClient(
                baseURLProvider: { [baseURL] in baseURL },
                session: URLSession(configuration: config),
                authHeaderProvider: { "Bearer test" },
                versionGate: gate
            )
        }
    }

    @Test("A page decodes from the backend's body, ids, operations and payloads included")
    func decodesTheBackendsPage() async throws {
        let backend = Backend()
        backend.answer(backend.feedURL(since: 40), status: 200, """
            {"current_revision": 42, "returned_until_revision": 42, "has_more": false, "changes": [
              {"revision": 41, "entity_type": "assignment", "entity_id": "7", "operation": "delete",
               "payload": null},
              {"revision": 42, "entity_type": "settings_document", "entity_id": "notification",
               "operation": "upsert", "payload": {"revision": 3}}
            ]}
            """)

        let page = try await backend.makeClient().fetchChanges(sinceRevision: 40)

        #expect(page == PushAPI.SyncChangesPage(
            currentRevision: 42,
            returnedUntilRevision: 42,
            hasMore: false,
            changes: [.init(revision: 41, entityType: "assignment"),
                      .init(revision: 42, entityType: "settings_document")]
        ))
        #expect(SettingsAPIStub.requests(for: backend.feedURL(since: 40)).map(\.httpMethod) == ["GET"])
    }

    @Test("Compacted changes throw as expired and leave the version gate alone; another 410 latches it")
    func expiredRevisionSkipsTheVersionGate() async {
        let backend = Backend()
        let client = backend.makeClient()
        backend.answer(backend.feedURL(since: 5), status: 410, """
            {"error": "sync_revision_expired", "min_available_revision": 90, "current_revision": 120,
             "full_sync_required": true}
            """)

        let error = await #expect(throws: PushAPIError.self) {
            _ = try await client.fetchChanges(sinceRevision: 5)
        }
        guard case .syncRevisionExpired = error else {
            Issue.record("expected an expired revision, got \(String(describing: error))")
            return
        }
        #expect(!backend.gate.isRetired)

        backend.answer(backend.feedURL(since: 6), status: 410, """
            {"detail": "This API version has been retired.", "current_api": "/v4"}
            """)
        await #expect(throws: PushAPIError.self) { _ = try await client.fetchChanges(sinceRevision: 6) }
        #expect(backend.gate.isRetired)
    }

    @Test("A body of another shape throws a decoding failure")
    func malformedPageFailsToDecode() async {
        let backend = Backend()
        backend.answer(backend.feedURL(since: 40), status: 200, #"{"current_revision": 42}"#)

        let error = await #expect(throws: PushAPIError.self) {
            _ = try await backend.makeClient().fetchChanges(sinceRevision: 40)
        }
        guard case .decodingFailed = error else {
            Issue.record("expected a decoding failure, got \(String(describing: error))")
            return
        }
    }
}
