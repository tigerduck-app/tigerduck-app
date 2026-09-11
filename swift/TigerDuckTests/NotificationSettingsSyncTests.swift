// Pins the four behaviors the task brief calls out for
// `NotificationSettingsSync` (AppState+NotificationSettings.swift):
//
//   1. local -> document field mapping matches the brief's table exactly,
//      field by field (not sampling a couple of fields).
//   2. `courses` always round-trips untouched — the easiest thing to get
//      wrong, and the most damaging: clearing it silently turns off the
//      user's course reminders.
//   3. a 409 adopts the server's document and retries exactly once, never
//      looping forever.
//   4. `cloudSyncEnabled == false` sends no request at all, in either
//      direction.
//
// Exercises `NotificationSettingsSync` directly rather than through
// `AppState`, matching that type's own doc comment: nothing in this test
// target constructs a full `AppState` (SwiftData, `AuthService`, live push
// registration, etc.).
//
// `SettingsDocumentClient` (Task 2) is a concrete `actor`, not a protocol,
// so it cannot be swapped for a lightweight fake — its `init` already
// supports injecting a `URLSession`, which is the seam these tests use via
// a `URLProtocol` stub. Each test gets its own unique base URL so the
// stub's per-URL queues can't cross-contaminate between tests, including
// under Swift Testing's default parallel execution.
import Foundation
import Testing
@testable import TigerDuck

@Suite("Notification settings sync")
struct NotificationSettingsSyncTests {

    // MARK: - Fixtures

    private static func local(
        isAssignmentReminderEnabled: Bool = true,
        assignmentReminderOffsets: Set<AssignmentReminderOffset> = [.hr24, .hr2],
        showClassPreparingScenario: Bool = true,
        showInClassScenario: Bool = false,
        showAssignmentScenario: Bool = true,
        classPreparingLeadTime: TimeInterval = 3600,
        assignmentLiveActivityLeadTime: TimeInterval = 7200
    ) -> NotificationSettingsSync.LocalPreferences {
        .init(
            isAssignmentReminderEnabled: isAssignmentReminderEnabled,
            assignmentReminderOffsets: assignmentReminderOffsets,
            showClassPreparingScenario: showClassPreparingScenario,
            showInClassScenario: showInClassScenario,
            showAssignmentScenario: showAssignmentScenario,
            classPreparingLeadTime: classPreparingLeadTime,
            assignmentLiveActivityLeadTime: assignmentLiveActivityLeadTime
        )
    }

    /// A fresh, never-reused base URL per test so `SettingsAPIStub`'s
    /// request/response queues are namespaced per test even when Swift
    /// Testing runs tests concurrently.
    private static func uniqueBaseURL() -> URL {
        URL(string: "https://settings-stub.invalid/\(UUID().uuidString)/v3")!
    }

    private static func makeClient(baseURL: URL) -> SettingsDocumentClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        return SettingsDocumentClient(baseURLProvider: { baseURL }, session: URLSession(configuration: config))
    }

    private static func documentURL(_ baseURL: URL) -> URL {
        baseURL.appendingPathComponent("settings/notification")
    }

    private static func documentJSONObject(_ document: NotificationSettingsDocument) throws -> Any {
        let data = try JSONEncoder().encode(document)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Body of a successful `GET` — `{"document": ..., "revision": ...}`.
    private static func readEnvelope(document: NotificationSettingsDocument, revision: Int) throws -> Data {
        let object: [String: Any] = [
            "document": try documentJSONObject(document),
            "revision": revision,
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// Body of a successful `PUT` — just the new revision.
    private static func writeSuccess(revision: Int) throws -> Data {
        let object: [String: Any] = ["revision": revision]
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// Body of a `409` — `{"server": {"document": ..., "revision": ...}}`.
    private static func conflictEnvelope(document: NotificationSettingsDocument, revision: Int) throws -> Data {
        let server: [String: Any] = [
            "document": try documentJSONObject(document),
            "revision": revision,
        ]
        let object: [String: Any] = ["server": server]
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// `URLSession` may hand a `PUT`/`POST` body to a custom `URLProtocol`
    /// as either `httpBody` or `httpBodyStream` depending on how the
    /// request was constructed — read whichever is present.
    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    private static func sentEnvelope(from request: URLRequest) throws -> [String: Any] {
        let body = try #require(Self.bodyData(from: request))
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private static func decodedDocument(from jsonObject: Any?) throws -> NotificationSettingsDocument {
        let object = try #require(jsonObject)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
        return try JSONDecoder().decode(NotificationSettingsDocument.self, from: data)
    }

    // MARK: - 1. Local -> document field mapping, per the brief's table (field-by-field)

    @Test("assignments.enabled mirrors isAssignmentReminderEnabled exactly")
    func assignmentsEnabledMapsDirectly() {
        #expect(Self.local(isAssignmentReminderEnabled: true).assignmentsSection.enabled == true)
        #expect(Self.local(isAssignmentReminderEnabled: false).assignmentsSection.enabled == false)
    }

    @Test("assignments.reminder_offsets_hours mirrors the whole-hour offsets, descending")
    func assignmentOffsetsMapToHours() {
        let prefs = Self.local(assignmentReminderOffsets: [.hr2, .hr48, .hr24])
        #expect(prefs.assignmentsSection.reminderOffsetsHours == [48, 24, 2])
    }

    @Test("sub-hour offsets are dropped from reminder_offsets_hours, never truncated to a phantom 0")
    func subHourOffsetsDoNotCollideAtZero() {
        // 30/15/10/5-minute offsets would all round down to "0 hours" if
        // truncated instead of dropped, silently merging four distinct
        // user choices into one value.
        let prefs = Self.local(assignmentReminderOffsets: [.min30, .min15, .min10, .min5])
        #expect(prefs.assignmentsSection.reminderOffsetsHours.isEmpty)
    }

    @Test("all seven assignments + live_activity fields map to their own document field, independently")
    func everyFieldMapsToItsOwnDocumentField() {
        let prefs = Self.local(
            isAssignmentReminderEnabled: true,
            assignmentReminderOffsets: [.hr8],
            showClassPreparingScenario: true,
            showInClassScenario: false,
            showAssignmentScenario: true,
            classPreparingLeadTime: 900,
            assignmentLiveActivityLeadTime: 28_800
        )

        #expect(prefs.assignmentsSection.enabled == true)
        #expect(prefs.assignmentsSection.reminderOffsetsHours == [8])

        let liveActivity = prefs.liveActivitySection
        #expect(liveActivity.showClassPreparing == true)
        #expect(liveActivity.showInClass == false)
        #expect(liveActivity.showAssignment == true)
        #expect(liveActivity.classPreparingLeadSeconds == 900)
        #expect(liveActivity.assignmentLeadSeconds == 28_800)

        // Flip every boolean and re-check independently, so a field-swap
        // bug (e.g. showInClass wired to showAssignmentScenario) fails.
        let flipped = Self.local(
            showClassPreparingScenario: false,
            showInClassScenario: true,
            showAssignmentScenario: false
        ).liveActivitySection
        #expect(flipped.showClassPreparing == false)
        #expect(flipped.showInClass == true)
        #expect(flipped.showAssignment == false)
    }

    // MARK: - 2. `courses` round-trips untouched

    @Test("push preserves the server's existing courses section unchanged")
    func pushPreservesExistingCourses() async throws {
        let baseURL = Self.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = Self.makeClient(baseURL: baseURL)

        let existingCourses = NotificationSettingsDocument.Courses(enabled: true, reminderOffsetsMinutes: [10, 30])
        let existing = NotificationSettingsDocument(
            assignments: .init(enabled: false, reminderOffsetsHours: []),
            courses: existingCourses,
            liveActivity: nil
        )
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: try Self.readEnvelope(document: existing, revision: 1)), for: url)
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: try Self.writeSuccess(revision: 2)), for: url)

        try await NotificationSettingsSync.push(local: Self.local(), client: client, cloudSyncEnabled: true)

        let requests = SettingsAPIStub.requests(for: url)
        #expect(requests.map(\.httpMethod) == ["GET", "PUT"])

        let sent = try Self.sentEnvelope(from: requests[1])
        let sentDocument = try Self.decodedDocument(from: sent["document"])
        #expect(sentDocument.courses == existingCourses)
    }

    @Test("a fresh account with no existing document writes the inert default courses, not a guess")
    func firstEverWriteUsesDefaultCourses() async throws {
        let baseURL = Self.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = Self.makeClient(baseURL: baseURL)

        SettingsAPIStub.enqueue(.init(statusCode: 404, body: Data()), for: url)
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: try Self.writeSuccess(revision: 1)), for: url)

        try await NotificationSettingsSync.push(local: Self.local(), client: client, cloudSyncEnabled: true)

        let requests = SettingsAPIStub.requests(for: url)
        let sent = try Self.sentEnvelope(from: requests[1])
        #expect(sent["base_revision"] is NSNull)
        let sentDocument = try Self.decodedDocument(from: sent["document"])
        #expect(sentDocument.courses == NotificationSettingsSync.defaultCourses)
    }

    // MARK: - 3. 409 conflict: adopt server version, retry exactly once

    @Test("a single conflict adopts the server's courses + revision and retries once, then succeeds")
    func conflictRetriesOnceThenSucceeds() async throws {
        let baseURL = Self.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = Self.makeClient(baseURL: baseURL)

        let staleCourses = NotificationSettingsDocument.Courses(enabled: true, reminderOffsetsMinutes: [5])
        let stale = NotificationSettingsDocument(
            assignments: .init(enabled: true, reminderOffsetsHours: [24]),
            courses: staleCourses,
            liveActivity: nil
        )
        let serverCourses = NotificationSettingsDocument.Courses(enabled: false, reminderOffsetsMinutes: [])
        let serverWinner = NotificationSettingsDocument(
            assignments: .init(enabled: true, reminderOffsetsHours: [1]),
            courses: serverCourses,
            liveActivity: nil
        )

        SettingsAPIStub.enqueue(.init(statusCode: 200, body: try Self.readEnvelope(document: stale, revision: 1)), for: url)
        SettingsAPIStub.enqueue(.init(statusCode: 409, body: try Self.conflictEnvelope(document: serverWinner, revision: 5)), for: url)
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: try Self.writeSuccess(revision: 6)), for: url)

        try await NotificationSettingsSync.push(local: Self.local(), client: client, cloudSyncEnabled: true)

        let requests = SettingsAPIStub.requests(for: url)
        #expect(requests.map(\.httpMethod) == ["GET", "PUT", "PUT"])

        let retry = try Self.sentEnvelope(from: requests[2])
        #expect(retry["base_revision"] as? Int == 5)
        let retryDocument = try Self.decodedDocument(from: retry["document"])
        #expect(retryDocument.courses == serverCourses)
    }

    @Test("a second consecutive conflict gives up instead of retrying forever")
    func secondConflictStopsRetrying() async throws {
        let baseURL = Self.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = Self.makeClient(baseURL: baseURL)

        let courses = NotificationSettingsDocument.Courses(enabled: true, reminderOffsetsMinutes: [])
        let doc = NotificationSettingsDocument(
            assignments: .init(enabled: true, reminderOffsetsHours: []),
            courses: courses,
            liveActivity: nil
        )

        SettingsAPIStub.enqueue(.init(statusCode: 404, body: Data()), for: url)
        SettingsAPIStub.enqueue(.init(statusCode: 409, body: try Self.conflictEnvelope(document: doc, revision: 2)), for: url)
        SettingsAPIStub.enqueue(.init(statusCode: 409, body: try Self.conflictEnvelope(document: doc, revision: 3)), for: url)

        await #expect(throws: NotificationSettingsSync.SyncError.self) {
            try await NotificationSettingsSync.push(local: Self.local(), client: client, cloudSyncEnabled: true)
        }

        // Exactly GET + 2 PUTs — a third attempt would mean unbounded retrying.
        let requests = SettingsAPIStub.requests(for: url)
        #expect(requests.map(\.httpMethod) == ["GET", "PUT", "PUT"])
    }

    // MARK: - 4. `cloudSyncEnabled == false` sends nothing at all

    @Test("push sends no request whatsoever when cloud sync is off")
    func pushSendsNothingWhenSyncDisabled() async throws {
        let baseURL = Self.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = Self.makeClient(baseURL: baseURL)
        // Deliberately nothing enqueued: if a request were sent anyway, the
        // stub has nothing to serve and the call would throw instead of
        // returning cleanly.

        try await NotificationSettingsSync.push(local: Self.local(), client: client, cloudSyncEnabled: false)

        #expect(SettingsAPIStub.requests(for: url).isEmpty)
    }

    @Test("pull sends no request and returns nil when cloud sync is off")
    func pullSendsNothingWhenSyncDisabled() async throws {
        let baseURL = Self.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = Self.makeClient(baseURL: baseURL)

        let result = try await NotificationSettingsSync.pull(client: client, cloudSyncEnabled: false)

        #expect(result == nil)
        #expect(SettingsAPIStub.requests(for: url).isEmpty)
    }

    // MARK: - Pull correctness (supporting coverage for `pullNotificationSettings()`)

    @Test("pull decodes the current document when one exists")
    func pullDecodesExistingDocument() async throws {
        let baseURL = Self.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = Self.makeClient(baseURL: baseURL)

        let doc = NotificationSettingsDocument(
            assignments: .init(enabled: true, reminderOffsetsHours: [24]),
            courses: .init(enabled: true, reminderOffsetsMinutes: [10]),
            liveActivity: .init(
                showClassPreparing: true, showInClass: true, showAssignment: false,
                classPreparingLeadSeconds: 900, assignmentLeadSeconds: 1800
            )
        )
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: try Self.readEnvelope(document: doc, revision: 9)), for: url)

        let result = try await NotificationSettingsSync.pull(client: client, cloudSyncEnabled: true)
        #expect(result == doc)
    }

    @Test("pull returns nil when the user has never synced this namespace")
    func pullReturnsNilWhenNoDocumentExists() async throws {
        let baseURL = Self.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = Self.makeClient(baseURL: baseURL)
        SettingsAPIStub.enqueue(.init(statusCode: 404, body: Data()), for: url)

        let result = try await NotificationSettingsSync.pull(client: client, cloudSyncEnabled: true)
        #expect(result == nil)
    }
}

// MARK: - Test double

/// Minimal request/response double for `SettingsDocumentClient`. Scoped per
/// test via a unique base URL (`NotificationSettingsSyncTests.uniqueBaseURL`)
/// rather than one shared queue, so Swift Testing's default parallel test
/// execution cannot let one test consume another's canned response.
///
/// Explicitly `nonisolated`: this target defaults unannotated declarations
/// to `@MainActor` (`SWIFT_DEFAULT_ACTOR_ISOLATION`), but `startLoading()`
/// is invoked by `URLSession` on an arbitrary background queue,
/// synchronously — it has no way to `await` its way onto the main actor.
/// `nonisolated(unsafe)` on the two dictionaries is the manual-
/// synchronization escape hatch (guarded by `lock`), the same justification
/// `SettingsDocumentClient.swift` and `NotificationSettingsDocument.swift`
/// give for their own explicit `nonisolated`.
nonisolated final class SettingsAPIStub: URLProtocol {
    nonisolated struct StubResponse {
        let statusCode: Int
        let body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [String: [StubResponse]] = [:]
    nonisolated(unsafe) private static var requestLog: [String: [URLRequest]] = [:]

    static func enqueue(_ response: StubResponse, for url: URL) {
        lock.lock(); defer { lock.unlock() }
        responses[url.absoluteString, default: []].append(response)
    }

    static func requests(for url: URL) -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requestLog[url.absoluteString] ?? []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let key = url.absoluteString

        Self.lock.lock()
        Self.requestLog[key, default: []].append(request)
        let next = Self.responses[key]?.first
        if next != nil {
            Self.responses[key]?.removeFirst()
        }
        Self.lock.unlock()

        guard let next else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: next.statusCode, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: next.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
