// `SettingsDocumentClient`'s own surface, driven through `SettingsAPIStub`.
//
// Everything risky in this client is wire-format handling with no type
// system behind it: the `{"schema_version","document","base_revision"}`
// request envelope, the `NSNull` base-revision-for-create encoding, 404 →
// `nil`, 409 → `.conflict` parsed out of `server.document`/`server.revision`,
// and the `revision` extraction on a successful write. Each of those is a
// dictionary subscript against a contract defined in another repo
// (`server/routes/settings_docs.py`, `server/sync/serializers.py`), so the
// compiler has nothing to say about any of it.
//
// Response shapes are copied from the live backend:
//   GET / PUT-success  `settings_document_to_dict` — {namespace,
//                      schema_version, document, revision, updated_at}
//   409                `_conflict_response` — {error, namespace,
//                      server: {…the same…}}
// The extra keys are included here deliberately: a parser that only works
// on a trimmed-down body is not a parser that works.
import Foundation
import Testing
@testable import TigerDuck

@Suite("Settings document client")
struct SettingsDocumentClientTests {

    private static func documentURL(_ baseURL: URL) -> URL {
        baseURL.appendingPathComponent("settings/notification")
    }

    /// A full `settings_document_to_dict` body, extra keys and all.
    private static func serverEnvelope(document: [String: Any], revision: Int) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "namespace": "notification",
            "schema_version": 1,
            "document": document,
            "revision": revision,
            "updated_at": "2026-09-11T10:00:00Z",
        ])
    }

    private static func conflictBody(document: [String: Any], revision: Int) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "error": "settings_conflict",
            "namespace": "notification",
            "server": [
                "namespace": "notification",
                "schema_version": 1,
                "document": document,
                "revision": revision,
                "updated_at": "2026-09-11T10:00:00Z",
            ],
        ])
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Read

    @Test("read unwraps the document and revision out of the server's envelope")
    func readParsesEnvelope() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)

        let document: [String: Any] = ["assignments": ["enabled": true, "reminder_offsets_hours": [24, 2]]]
        SettingsAPIStub.enqueue(
            .init(statusCode: 200, body: try Self.serverEnvelope(document: document, revision: 7)),
            for: url
        )

        let result = try #require(try await client.read(namespace: "notification"))

        #expect(result.revision == 7)
        // The `document` value only, lifted out of the envelope — not the
        // envelope itself, which is the easy thing to get wrong here.
        let parsed = try Self.object(result.document)
        #expect(Set(parsed.keys) == ["assignments"])
        let assignments = try #require(parsed["assignments"] as? [String: Any])
        #expect(assignments["reminder_offsets_hours"] as? [Int] == [24, 2])

        let requests = SettingsAPIStub.requests(for: url)
        #expect(requests.map(\.httpMethod) == ["GET"])
        #expect(requests[0].url?.path.hasSuffix("/settings/notification") == true)
    }

    @Test("read returns nil for 404 — a fresh account, not an error")
    func readReturnsNilOn404() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)
        SettingsAPIStub.enqueue(.init(statusCode: 404, body: Data(#"{"detail":"not found"}"#.utf8)), for: url)

        let result = try await client.read(namespace: "notification")

        #expect(result == nil)
    }

    @Test("read throws httpStatus for a non-2xx that is not 404")
    func readThrowsOnServerError() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)
        SettingsAPIStub.enqueue(.init(statusCode: 503, body: Data("upstream down".utf8)), for: url)

        await #expect(throws: PushAPIError.self) {
            _ = try await client.read(namespace: "notification")
        }
    }

    @Test("read sends the bearer token when there is a session, and no header when there isn't")
    func readAppliesAuthHeader() async throws {
        let withAuthBase = SettingsAPIStub.uniqueBaseURL()
        let withAuthURL = Self.documentURL(withAuthBase)
        let authed = SettingsAPIStub.makeClient(baseURL: withAuthBase, authHeaderProvider: { "Bearer token-abc" })
        SettingsAPIStub.enqueue(.init(statusCode: 404, body: Data()), for: withAuthURL)
        _ = try await authed.read(namespace: "notification")
        #expect(
            SettingsAPIStub.requests(for: withAuthURL)[0]
                .value(forHTTPHeaderField: "Authorization") == "Bearer token-abc"
        )

        let anonBase = SettingsAPIStub.uniqueBaseURL()
        let anonURL = Self.documentURL(anonBase)
        let anonymous = SettingsAPIStub.makeClient(baseURL: anonBase, authHeaderProvider: { nil })
        SettingsAPIStub.enqueue(.init(statusCode: 404, body: Data()), for: anonURL)
        _ = try await anonymous.read(namespace: "notification")
        #expect(
            SettingsAPIStub.requests(for: anonURL)[0]
                .value(forHTTPHeaderField: "Authorization") == nil
        )
    }

    // MARK: - Write envelope

    @Test("write wraps the document in the backend's envelope, with an explicit null base_revision on create")
    func writeSendsCreateEnvelope() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)
        SettingsAPIStub.enqueue(
            .init(statusCode: 200, body: try Self.serverEnvelope(document: ["a": 1], revision: 1)),
            for: url
        )

        let document = Data(#"{"courses":{"enabled":true}}"#.utf8)
        let result = try await client.write(namespace: "notification", document: document, baseRevision: nil)

        #expect(result == .written(revision: 1))

        let request = SettingsAPIStub.requests(for: url)[0]
        #expect(request.httpMethod == "PUT")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let sent = try Self.object(try #require(SettingsAPIStub.bodyData(from: request)))
        #expect(Set(sent.keys) == ["schema_version", "document", "base_revision"])
        #expect(sent["schema_version"] as? Int == 1)
        // Explicitly null, not omitted: `null` is what tells the backend
        // "create this namespace" (`SettingsPut.base_revision`).
        #expect(sent["base_revision"] is NSNull)
        // The caller's document travels as the `document` value, not
        // re-wrapped or stringified.
        let sentDocument = try #require(sent["document"] as? [String: Any])
        let courses = try #require(sentDocument["courses"] as? [String: Any])
        #expect(courses["enabled"] as? Bool == true)
    }

    @Test("write sends the base revision as an integer for a compare-and-swap")
    func writeSendsCASEnvelope() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)
        SettingsAPIStub.enqueue(
            .init(statusCode: 200, body: try Self.serverEnvelope(document: ["a": 1], revision: 12)),
            for: url
        )

        let result = try await client.write(
            namespace: "notification",
            document: Data("{}".utf8),
            baseRevision: 11
        )

        #expect(result == .written(revision: 12))
        let sent = try Self.object(
            try #require(SettingsAPIStub.bodyData(from: SettingsAPIStub.requests(for: url)[0]))
        )
        #expect(sent["base_revision"] as? Int == 11)
    }

    // MARK: - Conflict

    @Test("a 409 comes back as .conflict carrying the winning document, not as a thrown error")
    func writeReturnsConflict() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)

        let winner: [String: Any] = ["courses": ["enabled": false, "reminder_offsets_minutes": [5]]]
        SettingsAPIStub.enqueue(
            .init(statusCode: 409, body: try Self.conflictBody(document: winner, revision: 42)),
            for: url
        )

        let result = try await client.write(
            namespace: "notification",
            document: Data("{}".utf8),
            baseRevision: 3
        )

        guard case .conflict(let document, let revision) = result else {
            Issue.record("expected .conflict, got \(result)")
            return
        }
        #expect(revision == 42)
        // Read out of `server.document`, not out of the top level — the top
        // level of a 409 body has no `document` key at all, so a parser
        // looking in the wrong place would have thrown instead.
        let parsed = try Self.object(document)
        let courses = try #require(parsed["courses"] as? [String: Any])
        #expect(courses["enabled"] as? Bool == false)
        #expect(courses["reminder_offsets_minutes"] as? [Int] == [5])
    }

    @Test("a 409 whose body is missing the server block is a decoding failure, not a silent success")
    func malformedConflictThrows() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)
        SettingsAPIStub.enqueue(
            .init(statusCode: 409, body: Data(#"{"error":"settings_conflict"}"#.utf8)),
            for: url
        )

        await #expect(throws: PushAPIError.self) {
            _ = try await client.write(namespace: "notification", document: Data("{}".utf8), baseRevision: 1)
        }
    }

    // MARK: - Malformed bodies

    @Test("a body that is not JSON at all surfaces as PushAPIError, not a raw JSONSerialization error")
    func nonJSONBodyThrowsPushAPIError() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)
        // What a captive portal or a misconfigured proxy actually returns.
        SettingsAPIStub.enqueue(
            .init(statusCode: 200, body: Data("<html><body>502 Bad Gateway</body></html>".utf8)),
            for: url
        )

        await #expect(throws: PushAPIError.self) {
            _ = try await client.read(namespace: "notification")
        }
    }

    @Test("a 200 read with no revision key is a decoding failure, not revision 0")
    func readWithoutRevisionThrows() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)
        SettingsAPIStub.enqueue(
            .init(statusCode: 200, body: Data(#"{"document":{"assignments":{"enabled":true}}}"#.utf8)),
            for: url
        )

        await #expect(throws: PushAPIError.self) {
            _ = try await client.read(namespace: "notification")
        }
    }

    @Test("a 200 write with no revision key is a decoding failure, not a silent success")
    func writeWithoutRevisionThrows() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data(#"{"namespace":"notification"}"#.utf8)), for: url)

        await #expect(throws: PushAPIError.self) {
            _ = try await client.write(namespace: "notification", document: Data("{}".utf8), baseRevision: nil)
        }
    }

    // MARK: - APIVersionGate

    /// The gate latches for the whole process by design, so this is the
    /// **only** test in the target that touches it — both halves live in
    /// one test rather than two so they cannot race each other's reset, and
    /// no other test sends a 410. (404 and 409, which this client hands to
    /// the gate on its normal paths, do not latch it — the first half here
    /// is what proves the assertion in the second half means something.)
    @Test("the version gate latches on 410 and only on 410")
    @MainActor
    func versionGateSeesEveryStatusButLatchesOnlyOnGone() async throws {
        APIVersionGate.shared.resetForTesting()
        defer { APIVersionGate.shared.resetForTesting() }

        let quietBase = SettingsAPIStub.uniqueBaseURL()
        let quietURL = Self.documentURL(quietBase)
        let quiet = SettingsAPIStub.makeClient(baseURL: quietBase)
        SettingsAPIStub.enqueue(.init(statusCode: 404, body: Data()), for: quietURL)
        _ = try await quiet.read(namespace: "notification")
        #expect(APIVersionGate.shared.isRetired == false)

        let goneBase = SettingsAPIStub.uniqueBaseURL()
        let goneURL = Self.documentURL(goneBase)
        let gone = SettingsAPIStub.makeClient(baseURL: goneBase)
        SettingsAPIStub.enqueue(.init(statusCode: 410, body: Data(#"{"detail":"gone"}"#.utf8)), for: goneURL)
        await #expect(throws: PushAPIError.self) {
            _ = try await gone.read(namespace: "notification")
        }
        #expect(APIVersionGate.shared.isRetired)
    }
}
