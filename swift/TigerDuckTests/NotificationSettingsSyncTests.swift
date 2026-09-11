// `NotificationSettingsSync` (AppState+NotificationSettings.swift), end to
// end through the real `SettingsDocumentClient` and `SettingsAPIStub`.
//
// Pins:
//
//   1. local -> document field mapping matches the brief's table exactly,
//      field by field (not sampling a couple of fields).
//   2. every key this app does NOT own round-trips untouched — `courses`
//      (clearing it silently turns off the user's class reminders), whole
//      sections another client added, and unknown keys *inside* the two
//      sections this app does own.
//   3. a 409 adopts the server's document and retries exactly once, never
//      looping forever.
//   4. `cloudSyncEnabled == false` sends no request at all, in either
//      direction.
//   5. a document written by a client that knows about fewer keys than
//      this one degrades — it never wedges the push or resets a local
//      preference to a guess.
//   6. a pull can never delete a reminder offset the document structurally
//      cannot describe.
//
// Exercises `NotificationSettingsSync` directly rather than through
// `AppState`, matching that type's own doc comment: nothing in this test
// target constructs a full `AppState` (SwiftData, `AuthService`, live push
// registration, etc.). The seam is `SettingsAPIStub` — see that file.
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
        // user choices into one value. `reminder_offsets_hours` is the
        // field the backend scheduler reads and Android types as
        // `List<Int>`, so it stays whole hours only.
        let prefs = Self.local(assignmentReminderOffsets: [.min30, .min15, .min10, .min5])
        #expect(prefs.assignmentsSection.reminderOffsetsHours == [])
    }

    @Test("assignments.reminder_offsets_minutes carries every offset, sub-hour included")
    func minutesCarryTheCompleteOffsetSet() {
        // The lossless half of the pair: `reminder_offsets_hours` is a
        // strict subset for old readers, `reminder_offsets_minutes` is the
        // whole truth. Without it a pull has no way to learn about — or to
        // turn off — a sub-hour offset.
        let prefs = Self.local(assignmentReminderOffsets: [.hr24, .hr1, .min30, .min5])
        #expect(prefs.assignmentsSection.reminderOffsetsMinutes == [1440, 60, 30, 5])
        #expect(prefs.assignmentsSection.reminderOffsetsHours == [24, 1])

        // Sub-hour only: the hours array empties out, the minutes array
        // does not.
        let subHourOnly = Self.local(assignmentReminderOffsets: [.min30, .min15, .min10, .min5])
        #expect(subHourOnly.assignmentsSection.reminderOffsetsHours == [])
        #expect(subHourOnly.assignmentsSection.reminderOffsetsMinutes == [30, 15, 10, 5])
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
        // Android writes this same namespace (spec W6) and the route
        // accepts any object at all, so schema growth from another client
        // is planned, not hypothetical. A write that re-encodes a typed
        // struct deletes all four of the keys asserted below.
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
        // Writing `courses: {enabled: false}` here would be a guess with
        // teeth: the backend reads `enabled` literally
        // (`server/push/course_reminders.py`, `bool(section.get("enabled",
        // True))`), so inventing `false` for a user whose course reminders
        // the server was happily sending from its own defaults turns them
        // off. An absent `courses` key means "no opinion", which is the
        // truth — this app does not own that section.
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

    // MARK: - Step 6b: per-device-switch section gating (Task 4)
    //
    // `syncAssignmentRemindersEnabled` / `syncLiveActivityEnabled` gate
    // `assignments` / `live_activity` independently: a section whose switch
    // is off is left exactly as the server currently holds it (never
    // overwritten with the local value), and when both are off nothing is
    // sent at all — mirroring how `courses` is already preserved above.

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

    // MARK: - Pending marker (Important 1 / Minor 2, fix round 2)

    @Test("the pending marker clears only when the write landed and nothing changed since")
    func canClearPendingMarkerRequiresWriteAndNoInterveningEdit() {
        let sent = Self.local()

        // The ordinary case: it landed, and the store still says what was sent.
        #expect(NotificationSettingsSync.canClearPendingMarker(written: true, sent: sent, current: sent))

        // Didn't run / didn't land: must never read as settled, or the
        // repair path (`retryUnacknowledgedNotificationSettings`) would
        // drop the change forever.
        #expect(!NotificationSettingsSync.canClearPendingMarker(written: false, sent: sent, current: sent))

        // Landed, but a newer edit arrived while the request was in
        // flight — the exact race Minor 2 names. That edit is already
        // queued behind this push (`enqueueNotificationSettingsPush`'s
        // chain); clearing here would let a kill in the next 250 ms lose
        // it with the marker already `false`.
        let editedWhileInFlight = Self.local(isAssignmentReminderEnabled: !sent.isAssignmentReminderEnabled)
        #expect(!NotificationSettingsSync.canClearPendingMarker(written: true, sent: sent, current: editedWhileInFlight))
    }

    // MARK: - Device switch re-enable reconcile (Minor 4, promoted, fix round 1)

    @Test("a device switch turning back on needs an extra push; turning it off does not")
    func shouldPushOnDeviceSwitchChangeOnlyFiresOnTheOffToOnTransition() {
        // The off→on transition: `push`'s per-section gating above just
        // re-included this section, but the device-preferences PATCH
        // (`AppState.pushSyncPreferences()`, called unconditionally on
        // every change either direction — not exercised here) only carries
        // the switch itself, never the section's content. Without this,
        // the section stays stale server-side until some unrelated local
        // edit happens to trigger a push — the exact hazard task-4-review's
        // Minor 4 named.
        #expect(NotificationSettingsSync.shouldPushOnDeviceSwitchChange(old: false, new: true))

        // The on→off transition needs no extra push: the section goes back
        // to being left exactly as the server holds it. Asserting this
        // too — not just the on-transition above — is what stops an
        // "always push regardless of direction" implementation from
        // passing: that would look right on the on-transition case alone
        // but reintroduce the unconditional-push shape this fix
        // deliberately narrows away from.
        #expect(!NotificationSettingsSync.shouldPushOnDeviceSwitchChange(old: true, new: false))
    }

    @Test("pull sends no request and returns nil when cloud sync is off")
    func pullSendsNothingWhenSyncDisabled() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)

        let result = try await NotificationSettingsSync.pull(client: client, cloudSyncEnabled: false)

        #expect(result == nil)
        #expect(SettingsAPIStub.requests(for: url).isEmpty)
    }

    // MARK: - 5. A partial or foreign document degrades instead of wedging

    @Test("a document with no assignments and no courses still pushes")
    func pushToleratesMissingSections() async throws {
        // Android's first write to this namespace carries `live_activity`
        // only (spec W6). Decoding that into a type with non-optional
        // `assignments`/`courses` threw, which made *every* push from this
        // device throw, forever, with only a log line.
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

    @Test("pull decodes a document that carries only one section")
    func pullToleratesPartialDocument() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)

        let existing: [String: Any] = ["live_activity": ["show_in_class": false]]
        SettingsAPIStub.enqueue(
            .init(statusCode: 200, body: try Self.readEnvelope(documentObject: existing, revision: 2)),
            for: url
        )

        let result = try #require(try await NotificationSettingsSync.pull(client: client, cloudSyncEnabled: true))

        #expect(result.assignments == nil)
        #expect(result.courses == nil)
        #expect(result.liveActivity?.showInClass == false)
        // Absent keys inside a present section are absent, not defaulted.
        #expect(result.liveActivity?.showAssignment == nil)
    }

    // MARK: - Pull correctness

    @Test("pull decodes the current document when one exists")
    func pullDecodesExistingDocument() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)

        let doc = NotificationSettingsDocument(
            assignments: .init(enabled: true, reminderOffsetsHours: [24], reminderOffsetsMinutes: [1440, 30]),
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
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)
        SettingsAPIStub.enqueue(.init(statusCode: 404, body: Data()), for: url)

        let result = try await NotificationSettingsSync.pull(client: client, cloudSyncEnabled: true)
        #expect(result == nil)
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
        // The Critical this round fixes. `.min30` ships in
        // `LiveActivityPreferencesStore.defaultOffsets`, and
        // `reminder_offsets_hours` structurally cannot carry it, so a
        // document that only has that field is not evidence the user
        // turned it off — it is evidence the writer could not say.
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

    @Test("an hours value large enough to overflow on ×60 is skipped, not trapped (Minor 1, fix round 2)")
    func resolveOffsetsToleratesOverflowingHours() {
        // `Int.max` is straight off a hostile/corrupt document — the route
        // does not validate `reminder_offsets_hours`. Pre-fix, `$0 * 60`
        // was a Swift arithmetic trap (a crash) for any value this large;
        // it must now just fail to match a case, same as any other
        // unrecognised value, while `24` still resolves normally and the
        // local sub-hour pick still survives (the unrelated C1 rule).
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

    // MARK: - Round trip

    @Test("a full push/pull round trip through the document preserves every offset exactly")
    func offsetsSurviveARoundTrip() {
        let original = LiveActivityPreferencesStore.defaultOffsets
        let section = Self.local(assignmentReminderOffsets: original).assignmentsSection
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
/// `LiveActivityPreferencesStore.applyFromNotificationSettingsDocument`,
/// against a real store.
///
/// `.serialized` and Defaults-restoring: `LiveActivityPreferencesStore`
/// reads and writes `UserDefaults.standard` through `Defaults`, and posts
/// on `NotificationCenter.default` — both process-wide. These are the only
/// tests in the target that construct one (verified by grep), so
/// serializing this suite is enough to keep them from tripping over each
/// other.
@Suite("Notification settings apply", .serialized)
@MainActor
struct NotificationSettingsApplyTests {

    /// Runs `body` with a fresh store, restoring every `Defaults` key the
    /// store touches afterwards.
    private static func withStore(_ body: (LiveActivityPreferencesStore) throws -> Void) rethrows {
        let savedOffsets = Defaults[.assignmentReminderOffsetsData]
        let savedEnabled = Defaults[.isAssignmentReminderEnabled]
        let savedLiveActivity = Defaults[.isLiveActivityEnabled]
        let savedAssignmentLead = Defaults[.assignmentLiveActivityLeadTime]
        let savedClassLead = Defaults[.classPreparingLeadTime]
        let savedShowAssignment = Defaults[.showAssignmentScenario]
        let savedShowClassPreparing = Defaults[.showClassPreparingScenario]
        let savedShowInClass = Defaults[.showInClassScenario]
        defer {
            Defaults[.assignmentReminderOffsetsData] = savedOffsets
            Defaults[.isAssignmentReminderEnabled] = savedEnabled
            Defaults[.isLiveActivityEnabled] = savedLiveActivity
            Defaults[.assignmentLiveActivityLeadTime] = savedAssignmentLead
            Defaults[.classPreparingLeadTime] = savedClassLead
            Defaults[.showAssignmentScenario] = savedShowAssignment
            Defaults[.showClassPreparingScenario] = savedShowClassPreparing
            Defaults[.showInClassScenario] = savedShowInClass
        }
        try body(LiveActivityPreferencesStore())
    }

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
    func pullDoesNotDeleteSubHourDefaults() throws {
        try Self.withStore { store in
            store.assignmentReminderOffsets = LiveActivityPreferencesStore.defaultOffsets

            // Exactly what this app's own push writes to
            // `reminder_offsets_hours` for the default offset set — and all
            // an older build, or a client that only knows that field, would
            // ever send.
            let document = NotificationSettingsDocument(
                assignments: .init(enabled: true, reminderOffsetsHours: [48, 24, 8, 2, 1])
            )

            NotificationSettingsSync.apply(document, to: store)

            #expect(store.assignmentReminderOffsets.contains(.min30))
            #expect(store.assignmentReminderOffsets == LiveActivityPreferencesStore.defaultOffsets)
        }
    }

    @Test("a pull carrying reminder_offsets_minutes can turn a sub-hour offset off")
    func pullWithMinutesRemovesSubHourOffset() throws {
        try Self.withStore { store in
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
    func applyWithoutAssignmentsLeavesLocalAlone() throws {
        try Self.withStore { store in
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
    func applyWithPartialLiveActivityKeepsLocalValues() throws {
        try Self.withStore { store in
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
    func applyPostsOneRemoteOriginNotification() throws {
        try Self.withStore { store in
            store.showInClassScenario = true
            store.showAssignmentScenario = true

            let document = NotificationSettingsDocument(
                assignments: .init(enabled: false, reminderOffsetsHours: [4]),
                liveActivity: .init(
                    showClassPreparing: false, showInClass: false, showAssignment: false,
                    classPreparingLeadSeconds: 600, assignmentLeadSeconds: 1200
                )
            )

            // Exactly one post, flagged remote-origin. One rather than one
            // per assigned property, because seven posts would mean seven
            // Live Activity refreshes and seven push-schedule syncs for a
            // single pull. Flagged rather than suppressed, because
            // `AppState`'s observer must still run those two — only the
            // outgoing settings push sits out.
            #expect(Self.recordedOrigins { NotificationSettingsSync.apply(document, to: store) } == [true])
        }
    }

    @Test("a local edit posts an un-flagged notification, so the push still fires")
    func localEditPostsWithoutRemoteOriginFlag() throws {
        try Self.withStore { store in
            let origins = Self.recordedOrigins {
                store.showInClassScenario = !store.showInClassScenario
            }

            #expect(origins == [false])
        }
    }

    @Test("a pull that changes nothing posts nothing")
    func applyWithNoChangePostsNothing() throws {
        try Self.withStore { store in
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
