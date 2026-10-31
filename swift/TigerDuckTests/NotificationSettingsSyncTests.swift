import Defaults
import Foundation
import Testing
@testable import TigerDuck

@Suite("Notification settings sync")
struct NotificationSettingsSyncTests {

    private static func local(
        isAssignmentReminderEnabled: Bool = true,
        assignmentReminderOffsets: Set<AssignmentReminderOffset> = [.hr24, .hr2],
        showClassPreparingScenario: Bool = true,
        showInClassScenario: Bool = false,
        showAssignmentScenario: Bool = true,
        classPreparingLeadTime: TimeInterval = 3600,
        assignmentLiveActivityLeadTime: TimeInterval = 7200,
        isClassReminderEnabled: Bool = true,
        classReminderLeadMinutes: Int = 10,
        hasPickedClassReminderLead: Bool = false
    ) -> NotificationSettingsSync.LocalPreferences {
        .init(
            isAssignmentReminderEnabled: isAssignmentReminderEnabled,
            assignmentReminderOffsets: assignmentReminderOffsets,
            showClassPreparingScenario: showClassPreparingScenario,
            showInClassScenario: showInClassScenario,
            showAssignmentScenario: showAssignmentScenario,
            classPreparingLeadTime: classPreparingLeadTime,
            assignmentLiveActivityLeadTime: assignmentLiveActivityLeadTime,
            isClassReminderEnabled: isClassReminderEnabled,
            classReminderLeadMinutes: classReminderLeadMinutes,
            hasPickedClassReminderLead: hasPickedClassReminderLead
        )
    }

    private static func documentURL(_ baseURL: URL) -> URL {
        baseURL.appendingPathComponent("settings/notification")
    }

    private static func documentJSONObject(_ document: NotificationSettingsDocument) throws -> Any {
        let data = try JSONEncoder().encode(document)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private static func readEnvelope(document: NotificationSettingsDocument, revision: Int) throws -> Data {
        try readEnvelope(documentObject: try documentJSONObject(document), revision: revision)
    }

    private static func readEnvelope(documentObject: Any, revision: Int) throws -> Data {
        let object: [String: Any] = ["document": documentObject, "revision": revision]
        return try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
    }

    private static func writeSuccess(revision: Int) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["revision": revision])
    }

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

    private static func sentDocumentObject(from request: URLRequest) throws -> [String: Any] {
        try #require(try sentEnvelope(from: request)["document"] as? [String: Any])
    }

    private static func decodedDocument(from jsonObject: Any?) throws -> NotificationSettingsDocument {
        let object = try #require(jsonObject)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])
        return try JSONDecoder().decode(NotificationSettingsDocument.self, from: data)
    }

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
        let prefs = Self.local(assignmentReminderOffsets: [.min30, .min15, .min10, .min5])
        #expect(prefs.assignmentsSection(preservingForeignMinutesFrom: [:]).reminderOffsetsHours == [])
    }

    @Test("assignments.reminder_offsets_minutes carries every offset, sub-hour included")
    func minutesCarryTheCompleteOffsetSet() {
        let prefs = Self.local(assignmentReminderOffsets: [.hr24, .hr1, .min30, .min5])
        #expect(prefs.assignmentsSection(preservingForeignMinutesFrom: [:]).reminderOffsetsMinutes == [1440, 60, 30, 5])
        #expect(prefs.assignmentsSection(preservingForeignMinutesFrom: [:]).reminderOffsetsHours == [24, 1])

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

        let flipped = Self.local(
            showClassPreparingScenario: false,
            showInClassScenario: true,
            showAssignmentScenario: false
        ).liveActivitySection
        #expect(flipped.showClassPreparing == false)
        #expect(flipped.showInClass == true)
        #expect(flipped.showAssignment == false)
    }

    @Test("courses carries the class reminder switch and its one lead time")
    func coursesSectionMapsTheSwitchAndLeadTime() {
        let section = Self.local(isClassReminderEnabled: false, classReminderLeadMinutes: 15)
            .coursesSection(preservingOffsetsIn: [:])
        #expect(section == .init(enabled: false, reminderOffsetsMinutes: [15]))
        #expect(Self.local().coursesSection(preservingOffsetsIn: [:])
            == .init(enabled: true, reminderOffsetsMinutes: [10]))
    }

    @Test("push writes the courses section from the device's class reminder switch and lead time")
    func pushWritesCoursesFromTheDevice() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)

        let existing = NotificationSettingsDocument(
            assignments: .init(enabled: false, reminderOffsetsHours: []),
            courses: .init(enabled: true, reminderOffsetsMinutes: [10]),
            liveActivity: nil
        )
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: try Self.readEnvelope(document: existing, revision: 1)), for: url)
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: try Self.writeSuccess(revision: 2)), for: url)

        try await NotificationSettingsSync.push(
            local: Self.local(isClassReminderEnabled: false, classReminderLeadMinutes: 30, hasPickedClassReminderLead: true),
            base: Self.local(),
            client: client,
            cloudSyncEnabled: true
        )

        let requests = SettingsAPIStub.requests(for: url)
        #expect(requests.map(\.httpMethod) == ["GET", "PUT"])

        let sent = try Self.sentEnvelope(from: requests[1])
        let sentDocument = try Self.decodedDocument(from: sent["document"])
        #expect(sentDocument.courses == .init(enabled: false, reminderOffsetsMinutes: [30]))
    }

    @Test("push preserves every key it does not own — whole sections, and keys inside the sections it does own")
    func pushPreservesUnknownKeys() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)

        let existing: [String: Any] = [
            "assignments": [
                "enabled": false,
                "reminder_offsets_hours": [1],
                "assignments_future_key": "keep me",
            ],
            "courses": [
                "enabled": true,
                "reminder_offsets_minutes": [10],
                "courses_future_key": 7,
            ],
            "live_activity": [
                "show_in_class": false,
                "live_activity_future_key": ["nested": true],
            ],
            "future_section": ["x": 1],
        ]
        SettingsAPIStub.enqueue(
            .init(statusCode: 200, body: try Self.readEnvelope(documentObject: existing, revision: 4)),
            for: url
        )
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: try Self.writeSuccess(revision: 5)), for: url)

        try await NotificationSettingsSync.push(
            local: Self.local(
                isAssignmentReminderEnabled: true,
                showInClassScenario: true,
                classReminderLeadMinutes: 15,
                hasPickedClassReminderLead: true
            ),
            base: Self.local(isAssignmentReminderEnabled: false, assignmentReminderOffsets: [.hr1], showInClassScenario: false),
            client: client,
            cloudSyncEnabled: true
        )

        let sent = try Self.sentDocumentObject(from: SettingsAPIStub.requests(for: url)[1])

        let futureSection = try #require(sent["future_section"] as? [String: Any])
        #expect(futureSection["x"] as? Int == 1)

        let courses = try #require(sent["courses"] as? [String: Any])
        #expect(courses["enabled"] as? Bool == true)
        #expect(courses["reminder_offsets_minutes"] as? [Int] == [15])
        #expect(courses["courses_future_key"] as? Int == 7)

        let assignments = try #require(sent["assignments"] as? [String: Any])
        #expect(assignments["enabled"] as? Bool == true)
        #expect(assignments["reminder_offsets_hours"] as? [Int] == [24, 2])
        #expect(assignments["assignments_future_key"] as? String == "keep me")

        let liveActivity = try #require(sent["live_activity"] as? [String: Any])
        #expect(liveActivity["show_in_class"] as? Bool == true)
        let nested = try #require(liveActivity["live_activity_future_key"] as? [String: Any])
        #expect(nested["nested"] as? Bool == true)
    }

    @Test("a first-ever write sends the three sections this app owns, courses as the device has it")
    func firstEverWriteSendsCourses() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)

        SettingsAPIStub.enqueue(.init(statusCode: 404, body: Data()), for: url)
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: try Self.writeSuccess(revision: 1)), for: url)

        try await NotificationSettingsSync.push(local: Self.local(), base: Self.local(), client: client, cloudSyncEnabled: true)

        let requests = SettingsAPIStub.requests(for: url)
        let sent = try Self.sentEnvelope(from: requests[1])
        #expect(sent["base_revision"] is NSNull)
        let sentDocument = try #require(sent["document"] as? [String: Any])
        #expect(Set(sentDocument.keys) == ["assignments", "courses", "live_activity"])
        let courses = try #require(sentDocument["courses"] as? [String: Any])
        #expect(courses["enabled"] as? Bool == true)
        #expect(courses["reminder_offsets_minutes"] as? [Int] == [10])
    }

    @Test("a single conflict adopts the server's document + revision and retries once, then succeeds")
    func conflictRetriesOnceThenSucceeds() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)

        let stale: [String: Any] = [
            "assignments": ["enabled": true, "reminder_offsets_hours": [24]],
            "future_section": ["x": 1],
        ]
        let serverWinner: [String: Any] = [
            "assignments": ["enabled": true, "reminder_offsets_hours": [1]],
            "future_section": ["x": 2],
        ]
        SettingsAPIStub.enqueue(
            .init(statusCode: 200, body: try Self.readEnvelope(documentObject: stale, revision: 1)),
            for: url
        )
        SettingsAPIStub.enqueue(
            .init(
                statusCode: 409,
                body: try JSONSerialization.data(withJSONObject: [
                    "server": ["document": serverWinner, "revision": 5],
                ])
            ),
            for: url
        )
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: try Self.writeSuccess(revision: 6)), for: url)

        try await NotificationSettingsSync.push(local: Self.local(), base: Self.local(), client: client, cloudSyncEnabled: true)

        let requests = SettingsAPIStub.requests(for: url)
        #expect(requests.map(\.httpMethod) == ["GET", "PUT", "PUT"])

        let retry = try Self.sentEnvelope(from: requests[2])
        #expect(retry["base_revision"] as? Int == 5)
        let retryDocument = try #require(retry["document"] as? [String: Any])
        #expect((retryDocument["future_section"] as? [String: Any])?["x"] as? Int == 2)
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
            try await NotificationSettingsSync.push(local: Self.local(), base: Self.local(), client: client, cloudSyncEnabled: true)
        }

        let requests = SettingsAPIStub.requests(for: url)
        #expect(requests.map(\.httpMethod) == ["GET", "PUT", "PUT"])
    }

    @Test("two devices that change different fields of one section both keep their change")
    func twoDevicesKeepTheirOwnFields() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)
        let synced = Self.local()
        let original = try synced.documentUpdates(existing: [:])

        SettingsAPIStub.enqueue(.init(statusCode: 200, body: try Self.readEnvelope(documentObject: original, revision: 1)), for: url)
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: try Self.writeSuccess(revision: 2)), for: url)
        try await NotificationSettingsSync.push(
            local: Self.local(showInClassScenario: true), base: synced, client: client, cloudSyncEnabled: true
        )
        let afterFirst = try Self.sentDocumentObject(from: SettingsAPIStub.requests(for: url)[1])

        SettingsAPIStub.enqueue(.init(statusCode: 200, body: try Self.readEnvelope(documentObject: afterFirst, revision: 2)), for: url)
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: try Self.writeSuccess(revision: 3)), for: url)
        try await NotificationSettingsSync.push(
            local: Self.local(assignmentLiveActivityLeadTime: 5400), base: synced, client: client, cloudSyncEnabled: true
        )

        let requests = SettingsAPIStub.requests(for: url)
        #expect(requests.map(\.httpMethod) == ["GET", "PUT", "GET", "PUT"])
        let liveActivity = try #require(try Self.sentDocumentObject(from: requests[3])["live_activity"] as? [String: Any])
        #expect(liveActivity["show_in_class"] as? Bool == true)
        #expect(liveActivity["assignment_lead_seconds"] as? Int == 5400)
    }

    @Test("the conflict retry keeps the field the winning device changed, and sends this device's")
    func conflictRetryKeepsTheOtherDevicesField() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)
        let synced = Self.local()
        let original = try synced.documentUpdates(existing: [:])
        let winner = try Self.local(isAssignmentReminderEnabled: false, showInClassScenario: true)
            .documentUpdates(existing: [:])

        SettingsAPIStub.enqueue(.init(statusCode: 200, body: try Self.readEnvelope(documentObject: original, revision: 1)), for: url)
        SettingsAPIStub.enqueue(
            .init(statusCode: 409, body: try JSONSerialization.data(withJSONObject: ["server": ["document": winner, "revision": 2]])),
            for: url
        )
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: try Self.writeSuccess(revision: 3)), for: url)

        try await NotificationSettingsSync.push(
            local: Self.local(assignmentLiveActivityLeadTime: 5400), base: synced, client: client, cloudSyncEnabled: true
        )

        let requests = SettingsAPIStub.requests(for: url)
        #expect(requests.map(\.httpMethod) == ["GET", "PUT", "PUT"])
        let retry = try Self.sentDocumentObject(from: requests[2])
        let liveActivity = try #require(retry["live_activity"] as? [String: Any])
        #expect(liveActivity["show_in_class"] as? Bool == true)
        #expect(liveActivity["assignment_lead_seconds"] as? Int == 5400)
        #expect((retry["assignments"] as? [String: Any])?["enabled"] as? Bool == false)
    }

    @Test("a push with nothing changed since the synced copy writes only what the document lacks")
    func unchangedPushWritesOnlyWhatTheDocumentLacks() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)
        let existing: [String: Any] = [
            "assignments": ["enabled": false, "reminder_offsets_hours": [1]],
            "live_activity": ["show_in_class": true],
        ]
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: try Self.readEnvelope(documentObject: existing, revision: 4)), for: url)
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: try Self.writeSuccess(revision: 5)), for: url)

        try await NotificationSettingsSync.push(local: Self.local(), base: Self.local(), client: client, cloudSyncEnabled: true)

        let sent = try Self.sentDocumentObject(from: SettingsAPIStub.requests(for: url)[1])
        let assignments = try #require(sent["assignments"] as? [String: Any])
        #expect(assignments["enabled"] as? Bool == false)
        #expect(assignments["reminder_offsets_hours"] as? [Int] == [1])
        #expect(assignments["reminder_offsets_minutes"] == nil)
        let liveActivity = try #require(sent["live_activity"] as? [String: Any])
        #expect(liveActivity["show_in_class"] as? Bool == true)
        #expect(liveActivity["assignment_lead_seconds"] as? Int == 7200)
        #expect((sent["courses"] as? [String: Any])?["enabled"] as? Bool == true)
    }

    @Test("push sends no request whatsoever when cloud sync is off, and reports that it did not write")
    func pushSendsNothingWhenSyncDisabled() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)

        let written = try await NotificationSettingsSync.push(
            local: Self.local(), base: Self.local(), client: client, cloudSyncEnabled: false
        )

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
            local: Self.local(), base: Self.local(), client: client, cloudSyncEnabled: true
        )

        #expect(written)
    }

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
            base: Self.local(),
            client: client,
            cloudSyncEnabled: true,
            syncAssignmentRemindersEnabled: false,
            syncLiveActivityEnabled: true
        )

        #expect(written)
        let sent = try Self.sentDocumentObject(from: SettingsAPIStub.requests(for: url)[1])

        let sentAssignments = try #require(sent["assignments"] as? [String: Any])
        #expect(sentAssignments["enabled"] as? Bool == false)
        #expect(sentAssignments["reminder_offsets_hours"] as? [Int] == [1])

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
            base: Self.local(isAssignmentReminderEnabled: false),
            client: client,
            cloudSyncEnabled: true,
            syncAssignmentRemindersEnabled: true,
            syncLiveActivityEnabled: false
        )

        #expect(written)
        let sent = try Self.sentDocumentObject(from: SettingsAPIStub.requests(for: url)[1])

        let sentLiveActivity = try #require(sent["live_activity"] as? [String: Any])
        #expect(sentLiveActivity["show_in_class"] as? Bool == true)
        #expect(sentLiveActivity["assignment_lead_seconds"] as? Int == 999)

        let sentAssignments = try #require(sent["assignments"] as? [String: Any])
        #expect(sentAssignments["enabled"] as? Bool == true)
    }

    @Test("both device switches off still write courses, and leave the other two sections as the server holds them")
    func bothDeviceSwitchesOffWriteOnlyCourses() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)

        let existing: [String: Any] = [
            "assignments": ["enabled": false],
            "live_activity": ["show_in_class": true],
        ]
        SettingsAPIStub.enqueue(
            .init(statusCode: 200, body: try Self.readEnvelope(documentObject: existing, revision: 1)),
            for: url
        )
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: try Self.writeSuccess(revision: 2)), for: url)

        let written = try await NotificationSettingsSync.push(
            local: Self.local(isAssignmentReminderEnabled: true, showInClassScenario: false, isClassReminderEnabled: false),
            base: Self.local(),
            client: client,
            cloudSyncEnabled: true,
            syncAssignmentRemindersEnabled: false,
            syncLiveActivityEnabled: false
        )

        #expect(written)
        let sent = try Self.sentDocumentObject(from: SettingsAPIStub.requests(for: url)[1])
        #expect((sent["assignments"] as? [String: Any])?["enabled"] as? Bool == false)
        #expect((sent["live_activity"] as? [String: Any])?["show_in_class"] as? Bool == true)
        #expect((sent["courses"] as? [String: Any])?["enabled"] as? Bool == false)
    }

    @Test("the pending marker clears only when the write landed and nothing changed since")
    func canClearPendingMarkerRequiresWriteAndNoInterveningEdit() {
        let sent = Self.local()

        #expect(NotificationSettingsSync.canClearPendingMarker(written: true, sent: sent, current: sent))

        #expect(!NotificationSettingsSync.canClearPendingMarker(written: false, sent: sent, current: sent))

        let editedWhileInFlight = Self.local(isAssignmentReminderEnabled: !sent.isAssignmentReminderEnabled)
        #expect(!NotificationSettingsSync.canClearPendingMarker(written: true, sent: sent, current: editedWhileInFlight))
    }

    @Test("a device switch turning back on adopts the server's section; turning it off does not")
    func shouldAdoptOnDeviceSwitchChangeOnlyFiresOnTheOffToOnTransition() {
        #expect(NotificationSettingsSync.shouldAdoptOnDeviceSwitchChange(old: false, new: true))

        #expect(!NotificationSettingsSync.shouldAdoptOnDeviceSwitchChange(old: true, new: false))
    }

    @Test("a document with no assignments and no courses still pushes")
    func pushToleratesMissingSections() async throws {
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
            local: Self.local(), base: Self.local(), client: client, cloudSyncEnabled: true
        )

        #expect(written)
        let requests = SettingsAPIStub.requests(for: url)
        #expect(requests.map(\.httpMethod) == ["GET", "PUT"])
        let sent = try Self.sentDocumentObject(from: requests[1])
        #expect(Set(sent.keys) == ["assignments", "courses", "live_activity"])
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
            local: Self.local(), base: Self.local(), client: client, cloudSyncEnabled: true
        )

        #expect(written)
        let sent = try Self.sentDocumentObject(from: SettingsAPIStub.requests(for: url)[1])
        #expect(Set(sent.keys) == ["assignments", "courses", "live_activity"])
    }

    private static func sentAssignments(from request: URLRequest) throws -> [String: Any] {
        try #require(try sentDocumentObject(from: request)["assignments"] as? [String: Any])
    }

    @Test("a minute offset no local case represents is written back, not deleted")
    func pushKeepsForeignMinuteOffsets() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)

        let existing: [String: Any] = [
            "assignments": [
                "enabled": true,
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
            base: Self.local(assignmentReminderOffsets: [.hr24]),
            client: client,
            cloudSyncEnabled: true
        )

        let assignments = try Self.sentAssignments(from: SettingsAPIStub.requests(for: url)[1])
        #expect(assignments["reminder_offsets_minutes"] as? [Int] == [1440, 180, 120, 45])
        #expect(assignments["reminder_offsets_hours"] as? [Int] == [24, 3, 2])
    }

    @Test("a preserved zero or negative minute never reaches the legacy hours field")
    func foreignNonPositiveMinutesStayOutOfTheHoursMirror() {
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
            base: Self.local(),
            client: client,
            cloudSyncEnabled: true
        )

        let assignments = try Self.sentAssignments(from: SettingsAPIStub.requests(for: url)[1])
        #expect(assignments["reminder_offsets_minutes"] as? [Int] == [1440])
        #expect(assignments["reminder_offsets_hours"] as? [Int] == [24])
    }

    @Test("a conflict rebases the preserved values onto the winner's document, not the stale one")
    func pushRecomputesForeignOffsetsAfterAConflict() async throws {
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
            base: Self.local(),
            client: client,
            cloudSyncEnabled: true
        )

        let retried = try Self.sentAssignments(from: SettingsAPIStub.requests(for: url)[2])
        #expect(retried["reminder_offsets_minutes"] as? [Int] == [1440, 77])
    }

    @Test("a push leaves the server's class reminder offsets alone until the user picks a lead time here")
    func pushKeepsClassReminderOffsetsUntilAPick() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)

        let existing: [String: Any] = ["courses": ["enabled": true, "reminder_offsets_minutes": [10, 45]]]
        SettingsAPIStub.enqueue(
            .init(statusCode: 200, body: try Self.readEnvelope(documentObject: existing, revision: 1)),
            for: url
        )
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: try Self.writeSuccess(revision: 2)), for: url)

        try await NotificationSettingsSync.push(
            local: Self.local(isClassReminderEnabled: false, classReminderLeadMinutes: 10),
            base: Self.local(),
            client: client,
            cloudSyncEnabled: true
        )

        let courses = try #require(
            try Self.sentDocumentObject(from: SettingsAPIStub.requests(for: url)[1])["courses"] as? [String: Any]
        )
        #expect(courses["enabled"] as? Bool == false)
        #expect(courses["reminder_offsets_minutes"] as? [Int] == [10, 45])

        let picked = Self.local(classReminderLeadMinutes: 15, hasPickedClassReminderLead: true)
            .coursesSection(preservingOffsetsIn: existing)
        #expect(picked.reminderOffsetsMinutes == [15])
        let noList = Self.local(classReminderLeadMinutes: 30)
            .coursesSection(preservingOffsetsIn: ["courses": ["enabled": true]])
        #expect(noList.reminderOffsetsMinutes == [30])
    }

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
        let resolved = NotificationSettingsSync.resolveOffsets(
            documentMinutes: nil,
            documentHours: [16],
            currentLocal: [.hr48, .hr1, .min30]
        )
        #expect(resolved == [.hr16, .min30])
    }

    @Test("an hours value large enough to overflow on ×60 is skipped, not trapped")
    func resolveOffsetsToleratesOverflowingHours() {
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

    @Test("a pull shows the smallest class reminder lead time on offer, and any list it adopts clears the pick")
    func resolveClassReminderLeadShowsWhatThePageOffers() {
        let rows: [(name: Comment, minutes: [Int]?, lead: Int, picked: Bool)] = [
            ("one lead time on offer", [30], 30, false),
            ("one the page does not offer: the current lead time stays", [45], 15, false),
            ("several: the smallest shows, as it is on offer", [60, 10], 10, false),
            ("several whose smallest is not on offer", [90, 45], 15, false),
            ("an empty list, which no lead time shows", [], 15, false),
            ("no list: nothing changes", nil, 15, true),
        ]
        for row in rows {
            let resolved = NotificationSettingsSync.resolveClassReminderLead(
                documentMinutes: row.minutes, currentMinutes: 15, currentPicked: true
            )
            #expect(resolved.minutes == row.lead, row.name)
            #expect(resolved.picked == row.picked, row.name)
        }
    }

    private struct OffsetShape {
        let name: Comment
        let section: String
        var currentLocal: Set<AssignmentReminderOffset> = []
        let expected: Set<AssignmentReminderOffset>
    }

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

    @Test("a full push/pull round trip through the document preserves every offset exactly")
    func offsetsSurviveARoundTrip() {
        let original = LiveActivityPreferencesStore.defaultOffsets
        let section = Self.local(assignmentReminderOffsets: original).assignmentsSection(preservingForeignMinutesFrom: [:])
        let resolved = NotificationSettingsSync.resolveOffsets(
            documentMinutes: section.reminderOffsetsMinutes,
            documentHours: section.reminderOffsetsHours,
            currentLocal: []
        )
        #expect(resolved == original)
    }
}

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

            #expect(store.isAssignmentReminderEnabled)
            #expect(store.assignmentReminderOffsets == [.hr24, .min15])
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

    @Test("a pull adopts the class reminder switch and a lead time on offer, and a push writes them back")
    func pullAdoptsClassReminders() async throws {
        try await NotificationSettingsFixtures.withStore { store in
            store.isClassReminderEnabled = true
            store.classReminderLeadMinutes = 10

            let document = NotificationSettingsDocument(courses: .init(enabled: false, reminderOffsetsMinutes: [30]))
            NotificationSettingsSync.apply(document, to: store)

            #expect(store.isClassReminderEnabled == false)
            #expect(store.classReminderLeadMinutes == 30)
            #expect(!store.hasPickedClassReminderLead)
            let existing: [String: Any] = ["courses": ["enabled": false, "reminder_offsets_minutes": [30]]]
            let updates = try NotificationSettingsSync.LocalPreferences(from: store).documentUpdates(existing: existing)
            let courses = try #require(NotificationSettingsSync.merging(updates, into: existing)["courses"] as? [String: Any])
            #expect(courses["enabled"] as? Bool == false)
            #expect(courses["reminder_offsets_minutes"] as? [Int] == [30])
        }
    }

    @Test("a pull with class reminder offsets the page does not offer keeps them until the user picks a lead time")
    func pullKeepsClassReminderOffsetsUntilAPick() async {
        await NotificationSettingsFixtures.withStore { store in
            store.classReminderLeadMinutes = 15
            #expect(store.hasPickedClassReminderLead)
            let existing: [String: Any] = ["courses": ["reminder_offsets_minutes": [45]]]

            NotificationSettingsSync.apply(NotificationSettingsDocument(courses: .init(reminderOffsetsMinutes: [45])), to: store)

            #expect(store.classReminderLeadMinutes == 15)
            #expect(!store.hasPickedClassReminderLead)
            #expect(NotificationSettingsSync.LocalPreferences(from: store)
                .coursesSection(preservingOffsetsIn: existing).reminderOffsetsMinutes == nil)

            #expect(Self.recordedPushDecisions { store.classReminderLeadMinutes = 5 } == [true])
            #expect(store.hasPickedClassReminderLead)
            #expect(NotificationSettingsSync.LocalPreferences(from: store)
                .coursesSection(preservingOffsetsIn: existing).reminderOffsetsMinutes == [5])
        }
    }

    @Test("resetting the Live Activity settings leaves the class reminders alone")
    func resetLeavesClassRemindersAlone() async {
        await NotificationSettingsFixtures.withStore { store in
            store.isClassReminderEnabled = false
            store.classReminderLeadMinutes = 30

            store.resetToDefaults()

            #expect(store.isClassReminderEnabled == false)
            #expect(store.classReminderLeadMinutes == 30)
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

            #expect(Self.recordedPushDecisions { store.isLiveActivityEnabled = false } == [false])
            #expect(Self.recordedPushDecisions { store.showInClassScenario.toggle() } == [true])
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
