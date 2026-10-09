// `NotificationSettingsSync` end to end through the real `SettingsDocumentClient` over
// `SettingsAPIStub`, called directly: no test in this target builds a full `AppState` (SwiftData,
// `AuthService`, push registration). `NotificationSettingsReconcileTests` covers the read side.
import Defaults
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

    private static func documentURL(_ baseURL: URL) -> URL {
        baseURL.appendingPathComponent("settings/notification")
    }

    private static func documentJSONObject(_ document: NotificationSettingsDocument) throws -> Any {
        let data = try JSONEncoder().encode(document)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Body of a successful `GET` — `{"document": ..., "revision": ...}`.
    private static func readEnvelope(document: NotificationSettingsDocument, revision: Int) throws -> Data {
        try readEnvelope(documentObject: try documentJSONObject(document), revision: revision)
    }

    /// Same, for a document this build's type cannot express — the whole
    /// point of the forward-compatibility tests.
    private static func readEnvelope(documentObject: Any, revision: Int) throws -> Data {
        let object: [String: Any] = ["document": documentObject, "revision": revision]
        return try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
    }

    /// Body of a successful `PUT` — just the new revision.
    private static func writeSuccess(revision: Int) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["revision": revision])
    }

    /// Body of a `409` — `{"server": {"document": ..., "revision": ...}}`.
    private static func conflictEnvelope(document: NotificationSettingsDocument, revision: Int) throws -> Data {
        let server: [String: Any] = [
            "document": try documentJSONObject(document),
            "revision": revision,
        ]
        return try JSONSerialization.data(withJSONObject: ["server": server])
    }

    private static func sentEnvelope(from request: URLRequest) throws -> [String: Any] {
        let body = try #require(SettingsAPIStub.bodyData(from: request))
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    /// The `document` the client actually PUT, as a raw dictionary — the
    /// only view that can see keys `NotificationSettingsDocument` has no
    /// property for.
    private static func sentDocumentObject(from request: URLRequest) throws -> [String: Any] {
        try #require(try sentEnvelope(from: request)["document"] as? [String: Any])
    }

    private static func decodedDocument(from jsonObject: Any?) throws -> NotificationSettingsDocument {
        let object = try #require(jsonObject)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
        return try JSONDecoder().decode(NotificationSettingsDocument.self, from: data)
    }

    // MARK: - 1. Local -> document field mapping (field-by-field)

    @Test("assignments.enabled mirrors isAssignmentReminderEnabled exactly")
    func assignmentsEnabledMapsDirectly() {
        #expect(Self.local(isAssignmentReminderEnabled: true).assignmentsSection(preservingForeignMinutesFrom: [:]).enabled == true)
        #expect(Self.local(isAssignmentReminderEnabled: false).assignmentsSection(preservingForeignMinutesFrom: [:]).enabled == false)
    }

    @Test("assignments.reminder_offsets_hours mirrors the whole-hour offsets, descending")
    func assignmentOffsetsMapToHours() {
        let prefs = Self.local(assignmentReminderOffsets: [.hr2, .hr48, .hr24])
        #expect(prefs.assignmentsSection(preservingForeignMinutesFrom: [:]).reminderOffsetsHours == [48, 24, 2])
    }

    @Test("sub-hour offsets are dropped from reminder_offsets_hours, never truncated to a phantom 0")
    func subHourOffsetsDoNotCollideAtZero() {
        // Truncation would merge 30/15/10/5 minutes into one phantom "0 hours". Readers older
        // than `reminder_offsets_minutes` read `reminder_offsets_hours`, and Android types it
        // as `List<Int>`, so it holds whole hours only.
        let prefs = Self.local(assignmentReminderOffsets: [.min30, .min15, .min10, .min5])
        #expect(prefs.assignmentsSection(preservingForeignMinutesFrom: [:]).reminderOffsetsHours == [])
    }

    @Test("assignments.reminder_offsets_minutes carries every offset, sub-hour included")
    func minutesCarryTheCompleteOffsetSet() {
        // `reminder_offsets_hours` is a strict subset for old readers; `reminder_offsets_minutes`
        // is the whole set. Without it a pull cannot learn about, or turn off, a sub-hour offset.
        let prefs = Self.local(assignmentReminderOffsets: [.hr24, .hr1, .min30, .min5])
        #expect(prefs.assignmentsSection(preservingForeignMinutesFrom: [:]).reminderOffsetsMinutes == [1440, 60, 30, 5])
        #expect(prefs.assignmentsSection(preservingForeignMinutesFrom: [:]).reminderOffsetsHours == [24, 1])

        // Sub-hour only: the hours array empties out, the minutes array
        // does not.
        let subHourOnly = Self.local(assignmentReminderOffsets: [.min30, .min15, .min10, .min5])
        #expect(subHourOnly.assignmentsSection(preservingForeignMinutesFrom: [:]).reminderOffsetsHours == [])
        #expect(subHourOnly.assignmentsSection(preservingForeignMinutesFrom: [:]).reminderOffsetsMinutes == [30, 15, 10, 5])
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

        #expect(prefs.assignmentsSection(preservingForeignMinutesFrom: [:]).enabled == true)
        #expect(prefs.assignmentsSection(preservingForeignMinutesFrom: [:]).reminderOffsetsHours == [8])

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

    // MARK: - 2. Everything this app does not own round-trips untouched

    @Test("push preserves the server's existing courses section unchanged")
    func pushPreservesExistingCourses() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)

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

    @Test("push preserves every key it does not own — whole sections, and keys inside the sections it does own")
    func pushPreservesUnknownKeys() async throws {
        // Android writes this namespace too and the route accepts any object, so another client
        // growing the schema is expected. A write that re-encodes a typed struct deletes all four
        // keys asserted below. See docs/decisions/0002-notification-settings-json-merge.md.
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)

        let existing: [String: Any] = [
            // A key inside a section this app owns and overwrites.
            "assignments": [
                "enabled": false,
                "reminder_offsets_hours": [1],
                "assignments_future_key": "keep me",
            ],
            // A section this app never writes, with a key inside it that
            // this build's `Courses` type has no property for.
            "courses": [
                "enabled": true,
                "reminder_offsets_minutes": [10],
                "courses_future_key": 7,
            ],
            // The other section this app owns and overwrites.
            "live_activity": [
                "show_in_class": false,
                "live_activity_future_key": ["nested": true],
            ],
            // A whole section this build has never heard of.
            "future_section": ["x": 1],
        ]
        SettingsAPIStub.enqueue(
            .init(statusCode: 200, body: try Self.readEnvelope(documentObject: existing, revision: 4)),
            for: url
        )
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: try Self.writeSuccess(revision: 5)), for: url)

        try await NotificationSettingsSync.push(
            local: Self.local(isAssignmentReminderEnabled: true, showInClassScenario: true),
            client: client,
            cloudSyncEnabled: true
        )

        let sent = try Self.sentDocumentObject(from: SettingsAPIStub.requests(for: url)[1])

        // The unknown top-level section survives whole.
        let futureSection = try #require(sent["future_section"] as? [String: Any])
        #expect(futureSection["x"] as? Int == 1)

        // `courses` survives whole, including the key this build cannot
        // model — a typed round-trip would drop `courses_future_key`.
        let courses = try #require(sent["courses"] as? [String: Any])
        #expect(courses["enabled"] as? Bool == true)
        #expect(courses["reminder_offsets_minutes"] as? [Int] == [10])
        #expect(courses["courses_future_key"] as? Int == 7)

        // Inside a section this app *does* overwrite: the owned keys take
        // the local value, the unowned one survives.
        let assignments = try #require(sent["assignments"] as? [String: Any])
        #expect(assignments["enabled"] as? Bool == true)
        #expect(assignments["reminder_offsets_hours"] as? [Int] == [24, 2])
        #expect(assignments["assignments_future_key"] as? String == "keep me")

        let liveActivity = try #require(sent["live_activity"] as? [String: Any])
        #expect(liveActivity["show_in_class"] as? Bool == true)
        let nested = try #require(liveActivity["live_activity_future_key"] as? [String: Any])
        #expect(nested["nested"] as? Bool == true)
    }

    @Test("a first-ever write sends only the two sections this app owns — it does not invent a courses section")
    func firstEverWriteOmitsCourses() async throws {
        // `server/push/course_reminders.py` reads `courses.enabled` with a default of true, so
        // inventing `false` would turn off course reminders the server sends from its defaults.
        // An absent `courses` key means "no opinion": this app does not own that section.
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)

        SettingsAPIStub.enqueue(.init(statusCode: 404, body: Data()), for: url)
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: try Self.writeSuccess(revision: 1)), for: url)

        try await NotificationSettingsSync.push(local: Self.local(), client: client, cloudSyncEnabled: true)

        let requests = SettingsAPIStub.requests(for: url)
        let sent = try Self.sentEnvelope(from: requests[1])
        #expect(sent["base_revision"] is NSNull)
        let sentDocument = try #require(sent["document"] as? [String: Any])
        #expect(Set(sentDocument.keys) == ["assignments", "live_activity"])
    }

    // MARK: - 3. 409 conflict: adopt server version, retry exactly once

    @Test("a single conflict adopts the server's courses + revision and retries once, then succeeds")
    func conflictRetriesOnceThenSucceeds() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)

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
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)

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

    @Test("push sends no request whatsoever when cloud sync is off, and reports that it did not write")
    func pushSendsNothingWhenSyncDisabled() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)
        // Deliberately nothing enqueued: if a request were sent anyway, the
        // stub has nothing to serve and the call would throw instead of
        // returning cleanly.

        let written = try await NotificationSettingsSync.push(
            local: Self.local(), client: client, cloudSyncEnabled: false
        )

        // `false` is load-bearing: the caller clears the pending marker on
        // `true`, and "didn't run" must never read as "succeeded" or the
        // repair path would drop the change.
        #expect(written == false)
        #expect(SettingsAPIStub.requests(for: url).isEmpty)
    }

    @Test("a successful push reports that it wrote")
    func pushReportsWrite() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)
        SettingsAPIStub.enqueue(.init(statusCode: 404, body: Data()), for: url)
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: try Self.writeSuccess(revision: 1)), for: url)

        let written = try await NotificationSettingsSync.push(
            local: Self.local(), client: client, cloudSyncEnabled: true
        )

        #expect(written)
    }

    // MARK: - Per-device-switch section gating
    // `syncAssignmentRemindersEnabled` gates `assignments` and `syncLiveActivityEnabled` gates
    // `live_activity`. An off section keeps the server's copy, and with both off nothing is sent.

    @Test("assignments off leaves that section exactly as the server holds it, but live_activity still updates")
    func assignmentsOffPreservesServerAssignmentsSection() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)

        let serverAssignments = NotificationSettingsDocument.Assignments(enabled: false, reminderOffsetsHours: [1])
        let existing = NotificationSettingsDocument(
            assignments: serverAssignments,
            liveActivity: .init(showInClass: false)
        )
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: try Self.readEnvelope(document: existing, revision: 1)), for: url)
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: try Self.writeSuccess(revision: 2)), for: url)

        let written = try await NotificationSettingsSync.push(
            local: Self.local(isAssignmentReminderEnabled: true, showInClassScenario: true),
            client: client,
            cloudSyncEnabled: true,
            syncAssignmentRemindersEnabled: false,
            syncLiveActivityEnabled: true
        )

        #expect(written)
        let sent = try Self.sentDocumentObject(from: SettingsAPIStub.requests(for: url)[1])

        // The server's own values survive untouched — not the local ones
        // (`enabled: true`, offsets `[24, 2]` per `Self.local`'s defaults).
        let sentAssignments = try #require(sent["assignments"] as? [String: Any])
        #expect(sentAssignments["enabled"] as? Bool == false)
        #expect(sentAssignments["reminder_offsets_hours"] as? [Int] == [1])

        // live_activity's switch is on, so it does take the local value.
        let sentLiveActivity = try #require(sent["live_activity"] as? [String: Any])
        #expect(sentLiveActivity["show_in_class"] as? Bool == true)
    }

    @Test("live_activity off leaves that section exactly as the server holds it, but assignments still updates")
    func liveActivityOffPreservesServerLiveActivitySection() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)

        let serverLiveActivity = NotificationSettingsDocument.LiveActivity(showInClass: true, assignmentLeadSeconds: 999)
        let existing = NotificationSettingsDocument(
            assignments: .init(enabled: false, reminderOffsetsHours: []),
            liveActivity: serverLiveActivity
        )
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: try Self.readEnvelope(document: existing, revision: 1)), for: url)
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: try Self.writeSuccess(revision: 2)), for: url)

        let written = try await NotificationSettingsSync.push(
            local: Self.local(isAssignmentReminderEnabled: true),
            client: client,
            cloudSyncEnabled: true,
            syncAssignmentRemindersEnabled: true,
            syncLiveActivityEnabled: false
        )

        #expect(written)
        let sent = try Self.sentDocumentObject(from: SettingsAPIStub.requests(for: url)[1])

        // The server's own values survive untouched.
        let sentLiveActivity = try #require(sent["live_activity"] as? [String: Any])
        #expect(sentLiveActivity["show_in_class"] as? Bool == true)
        #expect(sentLiveActivity["assignment_lead_seconds"] as? Int == 999)

        // assignments' switch is on, so it does take the local value
        // (`enabled: true`), overwriting the server's `false`.
        let sentAssignments = try #require(sent["assignments"] as? [String: Any])
        #expect(sentAssignments["enabled"] as? Bool == true)
    }

    @Test("both device switches off sends no request whatsoever, and reports that it did not write")
    func bothDeviceSwitchesOffSendsNothing() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)
        // Deliberately nothing enqueued: if a request were sent anyway, the
        // stub has nothing to serve and the call would throw instead of
        // returning cleanly.

        let written = try await NotificationSettingsSync.push(
            local: Self.local(),
            client: client,
            cloudSyncEnabled: true,
            syncAssignmentRemindersEnabled: false,
            syncLiveActivityEnabled: false
        )

        #expect(written == false)
        #expect(SettingsAPIStub.requests(for: url).isEmpty)
    }

    // MARK: - Pending marker

    @Test("the pending marker clears only when the write landed and nothing changed since")
    func canClearPendingMarkerRequiresWriteAndNoInterveningEdit() {
        let sent = Self.local()

        // The ordinary case: it landed, and the store still says what was sent.
        #expect(NotificationSettingsSync.canClearPendingMarker(written: true, sent: sent, current: sent))

        // Didn't run / didn't land: must never read as settled, or the
        // repair path (`retryUnacknowledgedNotificationSettings`) would
        // drop the change forever.
        #expect(!NotificationSettingsSync.canClearPendingMarker(written: false, sent: sent, current: sent))

        // Landed, but a newer edit arrived in flight and is queued behind this push
        // (`enqueueNotificationSettingsPush`'s chain). Clearing here would let a kill in the
        // next 250 ms lose that edit with the marker already `false`.
        let editedWhileInFlight = Self.local(isAssignmentReminderEnabled: !sent.isAssignmentReminderEnabled)
        #expect(!NotificationSettingsSync.canClearPendingMarker(written: true, sent: sent, current: editedWhileInFlight))
    }

    // MARK: - Device switch re-enable reconcile

    @Test("a device switch turning back on needs an extra push; turning it off does not")
    func shouldPushOnDeviceSwitchChangeOnlyFiresOnTheOffToOnTransition() {
        // Off to on: `push` includes the section again, but `AppState.pushSyncPreferences()`,
        // the device-preferences PATCH sent on every change either way, carries only the switch.
        // Without this push the section stays stale on the server until an unrelated edit pushes.
        #expect(NotificationSettingsSync.shouldPushOnDeviceSwitchChange(old: false, new: true))

        // On to off needs no push: the section is left as the server holds it. Asserting this
        // direction too stops an implementation that pushes on every change from passing.
        #expect(!NotificationSettingsSync.shouldPushOnDeviceSwitchChange(old: true, new: false))
    }

    // MARK: - 5. A partial or foreign document degrades instead of wedging

    @Test("a document with no assignments and no courses still pushes")
    func pushToleratesMissingSections() async throws {
        // Android's first write to this namespace carries only `live_activity`. A type with
        // non-optional `assignments`/`courses` fails to decode that, which would make every push
        // from this device throw, forever, with only a log line.
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)

        let existing: [String: Any] = ["live_activity": ["show_assignment": false]]
        SettingsAPIStub.enqueue(
            .init(statusCode: 200, body: try Self.readEnvelope(documentObject: existing, revision: 3)),
            for: url
        )
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: try Self.writeSuccess(revision: 4)), for: url)

        let written = try await NotificationSettingsSync.push(
            local: Self.local(), client: client, cloudSyncEnabled: true
        )

        #expect(written)
        let requests = SettingsAPIStub.requests(for: url)
        #expect(requests.map(\.httpMethod) == ["GET", "PUT"])
        let sent = try Self.sentDocumentObject(from: requests[1])
        #expect(Set(sent.keys) == ["assignments", "live_activity"])
        // Still a compare-and-swap against the revision that was read.
        #expect(try Self.sentEnvelope(from: requests[1])["base_revision"] as? Int == 3)
    }

    @Test("a stored document that is not even a JSON object is written over rather than aborting the push")
    func pushToleratesNonObjectDocument() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)

        SettingsAPIStub.enqueue(
            .init(statusCode: 200, body: try Self.readEnvelope(documentObject: [1, 2, 3], revision: 8)),
            for: url
        )
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: try Self.writeSuccess(revision: 9)), for: url)

        let written = try await NotificationSettingsSync.push(
            local: Self.local(), client: client, cloudSyncEnabled: true
        )

        #expect(written)
        let sent = try Self.sentDocumentObject(from: SettingsAPIStub.requests(for: url)[1])
        #expect(Set(sent.keys) == ["assignments", "live_activity"])
    }

    // MARK: - 5b. Offsets this build has no case for survive a push

    /// Reads the `assignments` section out of the document the client PUT.
    private static func sentAssignments(from request: URLRequest) throws -> [String: Any] {
        try #require(try sentDocumentObject(from: request)["assignments"] as? [String: Any])
    }

    @Test("a minute offset no local case represents is written back, not deleted")
    func pushKeepsForeignMinuteOffsets() async throws {
        // `merging` keeps keys nobody mentions, but this app writes `reminder_offsets_minutes`
        // outright. A value only another version's enum knows would vanish the moment this device
        // edits any offset, so it is written back, as Android does.
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)

        let existing: [String: Any] = [
            "assignments": [
                "enabled": true,
                // 45 and 180 match no `AssignmentReminderOffset`; 1440 and
                // 120 are this device's own selection coming back.
                "reminder_offsets_minutes": [1440, 180, 120, 45],
                "reminder_offsets_hours": [24, 3, 2],
            ],
        ]
        SettingsAPIStub.enqueue(
            .init(statusCode: 200, body: try Self.readEnvelope(documentObject: existing, revision: 4)),
            for: url
        )
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: try Self.writeSuccess(revision: 5)), for: url)

        try await NotificationSettingsSync.push(
            local: Self.local(assignmentReminderOffsets: [.hr24, .hr2]),
            client: client,
            cloudSyncEnabled: true
        )

        let assignments = try Self.sentAssignments(from: SettingsAPIStub.requests(for: url)[1])
        #expect(assignments["reminder_offsets_minutes"] as? [Int] == [1440, 180, 120, 45])
        // The hours mirror derives from the same merged set, so the document's 180 stays in it
        // as 3. A separately computed hours list would drop it, and the two fields would describe
        // different sets.
        #expect(assignments["reminder_offsets_hours"] as? [Int] == [24, 3, 2])
    }

    @Test("a preserved zero or negative minute never reaches the legacy hours field")
    func foreignNonPositiveMinutesStayOutOfTheHoursMirror() {
        // `reminder_offsets_hours` means hours before the deadline to older readers, and has never
        // held less than 1. `0` and negatives divide evenly by 60, so a bare whole-hour test would
        // mirror them as reminders at or after the deadline. The minutes array still carries them.
        let existing: [String: Any] = [
            "assignments": ["reminder_offsets_minutes": [1440, 0, -120]],
        ]
        let section = Self.local(assignmentReminderOffsets: [.hr24])
            .assignmentsSection(preservingForeignMinutesFrom: existing)

        #expect(section.reminderOffsetsMinutes == [1440, 0, -120])
        #expect(section.reminderOffsetsHours == [24])
    }

    @Test("a value only in the legacy hours field is not preserved")
    func foreignHoursWithoutMinutesAreNotPreserved() {
        // Only a client older than the minutes field writes this shape, and hours were always lossy.
        let existing: [String: Any] = [
            "assignments": ["reminder_offsets_hours": [24, 12]],
        ]
        let section = Self.local(assignmentReminderOffsets: [.hr24])
            .assignmentsSection(preservingForeignMinutesFrom: existing)

        #expect(section.reminderOffsetsMinutes == [1440])
        #expect(section.reminderOffsetsHours == [24])
    }

    @Test("an offset this build does know, but the user deselected, is still removed")
    func pushRemovesDeselectedOffsetsItDoesKnow() async throws {
        // The other half of the rule: "preserve what this enum cannot
        // represent" must not become "never remove anything", or turning an
        // offset off would never sync.
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)

        let existing: [String: Any] = [
            "assignments": ["reminder_offsets_minutes": [2880, 1440, 30]],
        ]
        SettingsAPIStub.enqueue(
            .init(statusCode: 200, body: try Self.readEnvelope(documentObject: existing, revision: 1)),
            for: url
        )
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: try Self.writeSuccess(revision: 2)), for: url)

        try await NotificationSettingsSync.push(
            local: Self.local(assignmentReminderOffsets: [.hr24]),
            client: client,
            cloudSyncEnabled: true
        )

        let assignments = try Self.sentAssignments(from: SettingsAPIStub.requests(for: url)[1])
        #expect(assignments["reminder_offsets_minutes"] as? [Int] == [1440])
        #expect(assignments["reminder_offsets_hours"] as? [Int] == [24])
    }

    @Test("a conflict rebases the preserved values onto the winner's document, not the stale one")
    func pushRecomputesForeignOffsetsAfterAConflict() async throws {
        // What this device preserves depends on the document, so it is recomputed against the
        // one that won. Building the update once, before the retry loop, would write the loser's
        // foreign values and delete the winner's.
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)

        SettingsAPIStub.enqueue(
            .init(
                statusCode: 200,
                body: try Self.readEnvelope(
                    documentObject: ["assignments": ["reminder_offsets_minutes": [1440, 45]]],
                    revision: 1
                )
            ),
            for: url
        )
        SettingsAPIStub.enqueue(
            .init(
                statusCode: 409,
                body: try JSONSerialization.data(withJSONObject: [
                    "server": [
                        "document": ["assignments": ["reminder_offsets_minutes": [1440, 77]]],
                        "revision": 2,
                    ],
                ])
            ),
            for: url
        )
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: try Self.writeSuccess(revision: 3)), for: url)

        try await NotificationSettingsSync.push(
            local: Self.local(assignmentReminderOffsets: [.hr24]),
            client: client,
            cloudSyncEnabled: true
        )

        let retried = try Self.sentAssignments(from: SettingsAPIStub.requests(for: url)[2])
        #expect(retried["reminder_offsets_minutes"] as? [Int] == [1440, 77])
    }

    // MARK: - 6. Offset resolution on the pull side

    @Test("reminder_offsets_minutes is authoritative and complete, sub-hour offsets included")
    func resolveOffsetsPrefersMinutes() {
        let resolved = NotificationSettingsSync.resolveOffsets(
            documentMinutes: [1440, 120, 30, 5],
            documentHours: [24, 2],
            currentLocal: [.hr48, .min15]
        )
        #expect(resolved == [.hr24, .hr2, .min30, .min5])
    }

    @Test("an empty reminder_offsets_minutes really does mean the user turned everything off")
    func resolveOffsetsHonoursEmptyMinutes() {
        // The one case that must NOT be read as "no opinion": without this
        // a user could never turn their last reminder off from another
        // device.
        let resolved = NotificationSettingsSync.resolveOffsets(
            documentMinutes: [],
            documentHours: nil,
            currentLocal: [.hr24, .min30]
        )
        #expect(resolved.isEmpty)
    }

    @Test("a minutes value this build has no case for is skipped, not fatal")
    func resolveOffsetsSkipsUnknownMinutes() {
        let resolved = NotificationSettingsSync.resolveOffsets(
            documentMinutes: [1440, 7],
            documentHours: nil,
            currentLocal: []
        )
        #expect(resolved == [.hr24])
    }

    @Test("with only reminder_offsets_hours, the device's sub-hour offsets are kept, not deleted")
    func resolveOffsetsKeepsLocalSubHourWhenOnlyHoursArePresent() {
        // `reminder_offsets_hours` cannot carry `.min30`, which ships in
        // `LiveActivityPreferencesStore.defaultOffsets`. A document with only that field shows the
        // writer could not say, not that the user turned it off.
        let resolved = NotificationSettingsSync.resolveOffsets(
            documentMinutes: nil,
            documentHours: [48, 24, 8, 2, 1],
            currentLocal: LiveActivityPreferencesStore.defaultOffsets
        )
        #expect(resolved == LiveActivityPreferencesStore.defaultOffsets)
        #expect(resolved.contains(.min30))
    }

    @Test("with only reminder_offsets_hours, the whole-hour offsets still come from the document")
    func resolveOffsetsTakesHoursFromDocument() {
        // The other half: "keep the sub-hour ones" must not become "ignore
        // the document". A whole-hour offset dropped on another device has
        // to disappear here, and one added there has to appear.
        let resolved = NotificationSettingsSync.resolveOffsets(
            documentMinutes: nil,
            documentHours: [16],
            currentLocal: [.hr48, .hr1, .min30]
        )
        #expect(resolved == [.hr16, .min30])
    }

    @Test("an hours value large enough to overflow on ×60 is skipped, not trapped")
    func resolveOffsetsToleratesOverflowingHours() {
        // The route does not validate `reminder_offsets_hours`, so a hostile or corrupt document
        // can hold `Int.max`, where `$0 * 60` traps. It must match no case, like any unknown value,
        // while `24` still resolves and the local sub-hour pick survives.
        let resolved = NotificationSettingsSync.resolveOffsets(
            documentMinutes: nil,
            documentHours: [Int.max, 24],
            currentLocal: [.min30]
        )
        #expect(resolved == [.hr24, .min30])
    }

    @Test("a document with no offset fields at all changes nothing")
    func resolveOffsetsLeavesLocalAloneWhenDocumentIsSilent() {
        let current: Set<AssignmentReminderOffset> = [.hr24, .min10]
        let resolved = NotificationSettingsSync.resolveOffsets(
            documentMinutes: nil,
            documentHours: nil,
            currentLocal: current
        )
        #expect(resolved == current)
    }

    // MARK: - 6b. The same shapes the backend reads, resolved the same way

    /// One row of the shape table: an `assignments` section exactly as it
    /// sits in the document, and what this device must end up with.
    private struct OffsetShape {
        let name: Comment
        let section: String
        var currentLocal: Set<AssignmentReminderOffset> = []
        let expected: Set<AssignmentReminderOffset>
    }

    /// Decodes `section` as the document's `assignments` and resolves it,
    /// so the row exercises the decoder and the resolver together — which
    /// is what a document actually goes through, and where the divergence
    /// from the backend lived.
    private static func resolve(_ shape: OffsetShape) throws -> Set<AssignmentReminderOffset> {
        let document = try JSONDecoder().decode(
            NotificationSettingsDocument.self,
            from: Data(#"{"assignments":\#(shape.section)}"#.utf8)
        )
        return NotificationSettingsSync.resolveOffsets(
            documentMinutes: document.assignments?.reminderOffsetsMinutes,
            documentHours: document.assignments?.reminderOffsetsHours,
            currentLocal: shape.currentLocal
        )
    }

    @Test("every shape the backend's reader distinguishes resolves to the same offsets here")
    func resolvesEveryShapeTheBackendDistinguishes() throws {
        // Mirrors `_offsets_hours` / `_numbers` in `server/push/reminders.py`, which delivers these
        // reminders. A JSON array at `reminder_offsets_minutes` decides, minus non-numbers, even
        // when empty; anything else falls through to `reminder_offsets_hours`, read the same way.
        let shapes: [OffsetShape] = [
            .init(
                name: "a plain minutes list decides",
                section: #"{"reminder_offsets_minutes":[1440,120]}"#,
                expected: [.hr24, .hr2]
            ),
            .init(
                name: "an empty minutes list is a real answer: everything off",
                section: #"{"reminder_offsets_minutes":[],"reminder_offsets_hours":[24]}"#,
                currentLocal: [.hr48, .min30],
                expected: []
            ),
            .init(
                // The backend drops `"15"` and schedules for `[30]`. Discarding the whole list
                // here would fall back to hours, or keep the local set, off the same document.
                name: "one bad element does not discard the list",
                section: #"{"reminder_offsets_minutes":[30,"15"],"reminder_offsets_hours":[24]}"#,
                currentLocal: [.hr48],
                expected: [.min30]
            ),
            .init(
                name: "every element bad is still a list, and an empty one",
                section: #"{"reminder_offsets_minutes":["a","b"],"reminder_offsets_hours":[24]}"#,
                currentLocal: [.hr48, .min30],
                expected: []
            ),
            .init(
                name: "a null element is dropped like any other non-number",
                section: #"{"reminder_offsets_minutes":[1440,null,120]}"#,
                expected: [.hr24, .hr2]
            ),
            .init(
                // The backend keeps 30.5 as 0.508 hours; no offset either
                // client has is 30.5 minutes, so both end up with the same
                // resolved set.
                name: "a fractional element matches nothing, and takes nothing with it",
                section: #"{"reminder_offsets_minutes":[1440,30.5]}"#,
                expected: [.hr24]
            ),
            .init(
                name: "a minutes value that is a string is not a list: read hours",
                section: #"{"reminder_offsets_minutes":"nope","reminder_offsets_hours":[24]}"#,
                expected: [.hr24]
            ),
            .init(
                name: "an explicit null minutes is not a list either: read hours",
                section: #"{"reminder_offsets_minutes":null,"reminder_offsets_hours":[2]}"#,
                expected: [.hr2]
            ),
            .init(
                name: "an object at minutes is not a list either: read hours",
                section: #"{"reminder_offsets_minutes":{"a":1},"reminder_offsets_hours":[2]}"#,
                expected: [.hr2]
            ),
            .init(
                name: "absent minutes: read hours",
                section: #"{"reminder_offsets_hours":[8]}"#,
                expected: [.hr8]
            ),
            .init(
                // Same element rule on the hours list, and iOS's own rule
                // on top: a field that cannot carry sub-hour offsets is not
                // evidence the user turned them off.
                name: "one bad element does not discard the hours list either",
                section: #"{"reminder_offsets_hours":[24,"2"]}"#,
                currentLocal: [.hr48, .min30],
                expected: [.hr24, .min30]
            ),
            .init(
                name: "an empty hours list is a real answer too",
                section: #"{"reminder_offsets_hours":[]}"#,
                currentLocal: [.hr48, .min30],
                expected: [.min30]
            ),
            .init(
                // Where the two readers legitimately differ: with no answer
                // in the document the backend has only its own default to
                // fall back on, and a client has the user's actual choice.
                name: "neither field is a list: keep the local choice",
                section: #"{"reminder_offsets_minutes":3,"reminder_offsets_hours":"nope"}"#,
                currentLocal: [.hr24, .min10],
                expected: [.hr24, .min10]
            ),
            .init(
                name: "a section carrying neither field: keep the local choice",
                section: #"{"enabled":true}"#,
                currentLocal: [.hr24, .min10],
                expected: [.hr24, .min10]
            ),
        ]

        for shape in shapes {
            #expect(try Self.resolve(shape) == shape.expected, shape.name)
        }
    }

    // MARK: - Round trip

    @Test("a full push/pull round trip through the document preserves every offset exactly")
    func offsetsSurviveARoundTrip() {
        let original = LiveActivityPreferencesStore.defaultOffsets
        let section = Self.local(assignmentReminderOffsets: original).assignmentsSection(preservingForeignMinutesFrom: [:])
        let resolved = NotificationSettingsSync.resolveOffsets(
            documentMinutes: section.reminderOffsetsMinutes,
            documentHours: section.reminderOffsetsHours,
            currentLocal: []
        )
        // `currentLocal` is empty on purpose: the round trip has to be
        // lossless on its own, not by falling back on what was already
        // there.
        #expect(resolved == original)
    }
}

// MARK: - Applying a pull onto the real store

/// `NotificationSettingsSync.apply` and
/// `LiveActivityPreferencesStore.applyFromNotificationSettingsDocument`, against a real store.
///
/// `.serialized`, and every store made through `NotificationSettingsFixtures.withStore`: the
/// store reads and writes `UserDefaults.standard` through `Defaults` and posts on
/// `NotificationCenter.default`, both process-wide. Other suites build stores too (the
/// reconcile, seed-migration and push-queue tests) and suspend mid-test, so the fixture's
/// shared gate keeps one of them from running inside one of these.
@Suite("Notification settings apply", .serialized)
@MainActor
struct NotificationSettingsApplyTests {

    /// Thread-safe box for the observer block, which `NotificationCenter`
    /// treats as `@Sendable` even though `queue: nil` runs it synchronously
    /// on the posting thread.
    private final class OriginLog: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Bool] = []
        func append(_ value: Bool) { lock.lock(); values.append(value); lock.unlock() }
        var all: [Bool] { lock.lock(); defer { lock.unlock() }; return values }
    }

    /// One entry per `liveActivityPreferencesDidChange` post made while
    /// `body` runs: `true` if it was flagged remote-origin. `queue: nil` so
    /// the block runs synchronously and nothing has to be awaited.
    private static func recordedOrigins(_ body: () -> Void) -> [Bool] {
        let log = OriginLog()
        let token = NotificationCenter.default.addObserver(
            forName: AppConstants.liveActivityPreferencesDidChange,
            object: nil,
            queue: nil
        ) { note in
            log.append(note.userInfo?[AppConstants.liveActivityPreferencesRemoteOriginKey] as? Bool == true)
        }
        defer { NotificationCenter.default.removeObserver(token) }
        body()
        return log.all
    }

    @Test("a pull carrying only whole-hour offsets does not delete the shipped .min30 default")
    func pullDoesNotDeleteSubHourDefaults() async throws {
        await NotificationSettingsFixtures.withStore { store in
            store.assignmentReminderOffsets = LiveActivityPreferencesStore.defaultOffsets

            // What this app's own push writes to `reminder_offsets_hours` for the default offsets,
            // and all an older build, or a client that only knows that field, would ever send.
            let document = NotificationSettingsDocument(
                assignments: .init(enabled: true, reminderOffsetsHours: [48, 24, 8, 2, 1])
            )

            NotificationSettingsSync.apply(document, to: store)

            #expect(store.assignmentReminderOffsets.contains(.min30))
            #expect(store.assignmentReminderOffsets == LiveActivityPreferencesStore.defaultOffsets)
        }
    }

    @Test("a pull carrying reminder_offsets_minutes can turn a sub-hour offset off")
    func pullWithMinutesRemovesSubHourOffset() async throws {
        await NotificationSettingsFixtures.withStore { store in
            store.assignmentReminderOffsets = LiveActivityPreferencesStore.defaultOffsets

            let document = NotificationSettingsDocument(
                assignments: .init(
                    enabled: true,
                    reminderOffsetsHours: [48, 24, 8, 2, 1],
                    reminderOffsetsMinutes: [2880, 1440, 480, 120, 60]
                )
            )

            NotificationSettingsSync.apply(document, to: store)

            #expect(store.assignmentReminderOffsets == [.hr48, .hr24, .hr8, .hr2, .hr1])
            #expect(store.assignmentReminderOffsets.contains(.min30) == false)
        }
    }

    @Test("a document with no assignments section leaves the local assignment preferences alone")
    func applyWithoutAssignmentsLeavesLocalAlone() async throws {
        await NotificationSettingsFixtures.withStore { store in
            store.isAssignmentReminderEnabled = true
            store.assignmentReminderOffsets = [.hr24, .min15]

            let document = NotificationSettingsDocument(
                liveActivity: .init(showInClass: false)
            )

            NotificationSettingsSync.apply(document, to: store)

            // Not reset to a guessed default, and certainly not disabled.
            #expect(store.isAssignmentReminderEnabled)
            #expect(store.assignmentReminderOffsets == [.hr24, .min15])
            // The one field the document did carry still applied.
            #expect(store.showInClassScenario == false)
        }
    }

    @Test("fields absent from live_activity keep their local values")
    func applyWithPartialLiveActivityKeepsLocalValues() async throws {
        await NotificationSettingsFixtures.withStore { store in
            store.showClassPreparingScenario = true
            store.showAssignmentScenario = true
            store.classPreparingLeadTime = 1800
            store.assignmentLiveActivityLeadTime = 3600

            let document = NotificationSettingsDocument(
                liveActivity: .init(showAssignment: false)
            )

            NotificationSettingsSync.apply(document, to: store)

            #expect(store.showAssignmentScenario == false)
            #expect(store.showClassPreparingScenario)
            #expect(store.classPreparingLeadTime == 1800)
            #expect(store.assignmentLiveActivityLeadTime == 3600)
        }
    }

    @Test("applying a pull posts exactly one change notification, flagged remote-origin")
    func applyPostsOneRemoteOriginNotification() async throws {
        await NotificationSettingsFixtures.withStore { store in
            store.showInClassScenario = true
            store.showAssignmentScenario = true

            let document = NotificationSettingsDocument(
                assignments: .init(enabled: false, reminderOffsetsHours: [4]),
                liveActivity: .init(
                    showClassPreparing: false, showInClass: false, showAssignment: false,
                    classPreparingLeadSeconds: 600, assignmentLeadSeconds: 1200
                )
            )

            // One remote-origin post, not one per property: seven would mean seven Live Activity
            // refreshes and push-schedule syncs for one pull. Flagged, not suppressed: `AppState`'s
            // observer must still run those two; only the outgoing settings push sits out.
            #expect(Self.recordedOrigins { NotificationSettingsSync.apply(document, to: store) } == [true])
        }
    }

    @Test("a local edit posts an un-flagged notification, so the push still fires")
    func localEditPostsWithoutRemoteOriginFlag() async throws {
        await NotificationSettingsFixtures.withStore { store in
            let origins = Self.recordedOrigins {
                store.showInClassScenario = !store.showInClassScenario
            }

            #expect(origins == [false])
        }
    }

    /// For each `liveActivityPreferencesDidChange` post made while `body`
    /// runs, whether `AppState`'s observer queues a settings push for it
    /// (`NotificationSettingsSync.changeNeedsDocumentPush`).
    private static func recordedPushDecisions(_ body: () -> Void) -> [Bool] {
        let log = OriginLog()
        let token = NotificationCenter.default.addObserver(
            forName: AppConstants.liveActivityPreferencesDidChange,
            object: nil,
            queue: nil
        ) { note in
            log.append(NotificationSettingsSync.changeNeedsDocumentPush(note.userInfo))
        }
        defer { NotificationCenter.default.removeObserver(token) }
        body()
        return log.all
    }

    @Test("switching Live Activity off queues no settings push; an edit to a synced field still does")
    func deviceOnlyEditQueuesNoSettingsPush() async {
        await NotificationSettingsFixtures.withStore { store in
            store.isLiveActivityEnabled = true

            // Not in the document, so there is nothing for a push to write.
            #expect(Self.recordedPushDecisions { store.isLiveActivityEnabled = false } == [false])
            // A field the document carries still goes up.
            #expect(Self.recordedPushDecisions { store.showInClassScenario.toggle() } == [true])
            // And a pull still never bounces back as a push.
            let document = NotificationSettingsDocument(
                liveActivity: .init(showInClass: !store.showInClassScenario)
            )
            #expect(Self.recordedPushDecisions { NotificationSettingsSync.apply(document, to: store) } == [false])
        }
    }

    @Test("a pull that changes nothing posts nothing")
    func applyWithNoChangePostsNothing() async throws {
        await NotificationSettingsFixtures.withStore { store in
            store.isAssignmentReminderEnabled = true
            store.assignmentReminderOffsets = [.hr24, .min30]
            store.showClassPreparingScenario = true
            store.showInClassScenario = false
            store.showAssignmentScenario = true
            store.classPreparingLeadTime = 1800
            store.assignmentLiveActivityLeadTime = 3600

            let document = NotificationSettingsDocument(
                assignments: .init(
                    enabled: true,
                    reminderOffsetsHours: [24],
                    reminderOffsetsMinutes: [1440, 30]
                ),
                liveActivity: .init(
                    showClassPreparing: true,
                    showInClass: false,
                    showAssignment: true,
                    classPreparingLeadSeconds: 1800,
                    assignmentLeadSeconds: 3600
                )
            )

            let origins = Self.recordedOrigins {
                NotificationSettingsSync.apply(document, to: store)
            }

            #expect(origins.isEmpty)
        }
    }
}
