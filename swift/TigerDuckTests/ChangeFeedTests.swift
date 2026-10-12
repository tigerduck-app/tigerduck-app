// `PushAPIClient.fetchChanges`, the change feed read of the revision poll
// (https://github.com/tigerduck-app/tigerduck-app/issues/241). Bodies copy
// `server/routes/sync/snapshot.py`'s.
import Foundation
import Testing
@testable import TigerDuck

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
