import Defaults
import Foundation
import Testing
@testable import TigerDuck

@Suite("Notification settings reconcile", .serialized)
@MainActor
struct NotificationSettingsReconcileTests {
    private typealias Fixtures = NotificationSettingsFixtures

    private static func setDeviceValues(_ store: LiveActivityPreferencesStore) {
        store.isAssignmentReminderEnabled = false
        store.assignmentReminderOffsets = [.hr8, .min30]
        store.showClassPreparingScenario = false
        store.showInClassScenario = true
        store.showAssignmentScenario = true
        store.classPreparingLeadTime = 1800
        store.assignmentLiveActivityLeadTime = 5400
        store.isClassReminderEnabled = false
        store.classReminderLeadMinutes = 30
    }

    private static func serverAssignments() -> [String: Any] {
        ["enabled": true, "reminder_offsets_hours": [24, 2], "reminder_offsets_minutes": [1440, 120, 15]]
    }

    private static func serverLiveActivity() -> [String: Any] {
        [
            "show_class_preparing": true,
            "show_in_class": false,
            "show_assignment": false,
            "class_preparing_lead_seconds": 900,
            "assignment_lead_seconds": 7200,
        ]
    }

    private static func serverCourses() -> [String: Any] {
        ["enabled": true, "reminder_offsets_minutes": [5]]
    }

    private static func serverDocument() -> [String: Any] {
        ["assignments": serverAssignments(), "live_activity": serverLiveActivity(), "courses": serverCourses()]
    }

    private static func reconcile(
        _ store: LiveActivityPreferencesStore,
        client: SettingsDocumentClient,
        cloudSyncEnabled: Bool = true,
        syncAssignments: Bool = true,
        syncLiveActivity: Bool = true,
        isPushPending: () -> Bool = { false },
        source: NotificationSettingsSync.DocumentSource = .read,
        recordSynced: (NotificationSettingsSync.LocalPreferences) -> Void = { _ in }
    ) async throws -> NotificationSettingsSync.ReconcileOutcome {
        try await NotificationSettingsSync.reconcile(
            store: store,
            client: client,
            cloudSyncEnabled: cloudSyncEnabled,
            syncAssignmentRemindersEnabled: syncAssignments,
            syncLiveActivityEnabled: syncLiveActivity,
            isPushPending: isPushPending,
            source: source,
            recordSynced: recordSynced
        )
    }

    @Test("no document: every synced section is written from the device's values, reminders switched off included")
    func noDocumentSeedsTheDevicesValues() async throws {
        try await Fixtures.withStore { store in
            Self.setDeviceValues(store)
            let before = NotificationSettingsSync.LocalPreferences(from: store)
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let url = Fixtures.documentURL(baseURL)
            SettingsAPIStub.enqueue(Fixtures.notFound(), for: url)
            SettingsAPIStub.enqueue(try Fixtures.written(revision: 1), for: url)

            let outcome = try await Self.reconcile(store, client: SettingsAPIStub.makeClient(baseURL: baseURL))

            #expect(outcome == .settled(adopted: [], seeded: [.assignments, .liveActivity, .courses]))
            let requests = SettingsAPIStub.requests(for: url)
            try #require(requests.map(\.httpMethod) == ["GET", "PUT"])
            #expect(try Fixtures.sentEnvelope(requests[1])["base_revision"] is NSNull)
            let document = try Fixtures.sentDocument(requests[1])
            #expect(Set(document.keys) == ["assignments", "courses", "live_activity"])

            let assignments = try #require(document["assignments"] as? [String: Any])
            #expect(assignments["enabled"] as? Bool == false)
            #expect(assignments["reminder_offsets_minutes"] as? [Int] == [480, 30])
            #expect(assignments["reminder_offsets_hours"] as? [Int] == [8])

            let liveActivity = try #require(document["live_activity"] as? [String: Any])
            #expect(liveActivity["show_class_preparing"] as? Bool == false)
            #expect(liveActivity["show_in_class"] as? Bool == true)
            #expect(liveActivity["show_assignment"] as? Bool == true)
            #expect(liveActivity["class_preparing_lead_seconds"] as? Int == 1800)
            #expect(liveActivity["assignment_lead_seconds"] as? Int == 5400)

            let courses = try #require(document["courses"] as? [String: Any])
            #expect(courses["enabled"] as? Bool == false)
            #expect(courses["reminder_offsets_minutes"] as? [Int] == [30])

            #expect(NotificationSettingsSync.LocalPreferences(from: store) == before)
        }
    }

    @Test("the server has every section: each is adopted, field by field, and nothing is written")
    func presentDocumentIsAdoptedAndNothingWritten() async throws {
        try await Fixtures.withStore { store in
            Self.setDeviceValues(store)
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let url = Fixtures.documentURL(baseURL)
            SettingsAPIStub.enqueue(try Fixtures.found(Self.serverDocument(), revision: 7), for: url)
            SettingsAPIStub.enqueue(try Fixtures.written(revision: 8), for: url)

            let outcome = try await Self.reconcile(store, client: SettingsAPIStub.makeClient(baseURL: baseURL))

            #expect(outcome == .settled(adopted: [.assignments, .liveActivity, .courses], seeded: []))
            #expect(SettingsAPIStub.requests(for: url).map(\.httpMethod) == ["GET"])
            #expect(store.isAssignmentReminderEnabled == true)
            #expect(store.assignmentReminderOffsets == [.hr24, .hr2, .min15])
            #expect(store.showClassPreparingScenario == true)
            #expect(store.showInClassScenario == false)
            #expect(store.showAssignmentScenario == false)
            #expect(store.classPreparingLeadTime == 900)
            #expect(store.assignmentLiveActivityLeadTime == 7200)
            #expect(store.isClassReminderEnabled == true)
            #expect(store.classReminderLeadMinutes == 5)
        }
    }

    @Test("the server lacks one section: the rest are adopted, only it is written, and every other key survives")
    func partialDocumentAdoptsOneAndSeedsTheOther() async throws {
        try await Fixtures.withStore { store in
            Self.setDeviceValues(store)
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let url = Fixtures.documentURL(baseURL)
            let existing: [String: Any] = [
                "assignments": Self.serverAssignments(),
                "courses": ["enabled": true, "reminder_offsets_minutes": [10]],
                "future_section": ["x": 1],
            ]
            SettingsAPIStub.enqueue(try Fixtures.found(existing, revision: 3), for: url)
            SettingsAPIStub.enqueue(try Fixtures.written(revision: 4), for: url)

            let outcome = try await Self.reconcile(store, client: SettingsAPIStub.makeClient(baseURL: baseURL))

            #expect(outcome == .settled(adopted: [.assignments, .courses], seeded: [.liveActivity]))
            let requests = SettingsAPIStub.requests(for: url)
            try #require(requests.map(\.httpMethod) == ["GET", "PUT"])
            #expect(try Fixtures.sentEnvelope(requests[1])["base_revision"] as? Int == 3)
            let sent = try Fixtures.sentDocument(requests[1])

            #expect(store.isAssignmentReminderEnabled == true)
            #expect(store.assignmentReminderOffsets == [.hr24, .hr2, .min15])
            let assignments = try #require(sent["assignments"] as? [String: Any])
            #expect(assignments["enabled"] as? Bool == true)
            #expect(assignments["reminder_offsets_minutes"] as? [Int] == [1440, 120, 15])
            #expect(assignments["reminder_offsets_hours"] as? [Int] == [24, 2])

            let liveActivity = try #require(sent["live_activity"] as? [String: Any])
            #expect(liveActivity["show_class_preparing"] as? Bool == false)
            #expect(liveActivity["class_preparing_lead_seconds"] as? Int == 1800)
            #expect(liveActivity["assignment_lead_seconds"] as? Int == 5400)
            #expect(store.showInClassScenario == true)
            #expect(store.assignmentLiveActivityLeadTime == 5400)

            #expect(store.isClassReminderEnabled == true)
            #expect(store.classReminderLeadMinutes == 10)
            #expect((sent["courses"] as? [String: Any])?["reminder_offsets_minutes"] as? [Int] == [10])
            #expect((sent["future_section"] as? [String: Any])?["x"] as? Int == 1)
        }
    }

    @Test("a local edit still waiting to go up: nothing is read, adopted or written")
    func pendingEditSuppressesTheRead() async throws {
        try await Fixtures.withStore { store in
            Self.setDeviceValues(store)
            let before = NotificationSettingsSync.LocalPreferences(from: store)
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let url = Fixtures.documentURL(baseURL)
            SettingsAPIStub.enqueue(
                try Fixtures.found(
                    ["assignments": Self.serverAssignments(), "live_activity": Self.serverLiveActivity()],
                    revision: 2
                ),
                for: url
            )

            let outcome = try await Self.reconcile(
                store,
                client: SettingsAPIStub.makeClient(baseURL: baseURL),
                isPushPending: { true }
            )

            #expect(outcome == .deferredToPendingPush)
            #expect(SettingsAPIStub.requests(for: url).isEmpty)
            #expect(NotificationSettingsSync.LocalPreferences(from: store) == before)
        }
    }

    @Test("an edit whose push is pending by the time the read returns wins: the server's copy is not applied")
    func pendingEditDuringTheReadWins() async throws {
        try await Fixtures.withStore { store in
            Self.setDeviceValues(store)
            let before = NotificationSettingsSync.LocalPreferences(from: store)
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let url = Fixtures.documentURL(baseURL)
            SettingsAPIStub.enqueue(
                try Fixtures.found(
                    ["assignments": Self.serverAssignments(), "live_activity": Self.serverLiveActivity()],
                    revision: 2
                ),
                for: url
            )
            SettingsAPIStub.enqueue(try Fixtures.written(revision: 3), for: url)

            var checks = 0
            let outcome = try await Self.reconcile(
                store,
                client: SettingsAPIStub.makeClient(baseURL: baseURL),
                isPushPending: {
                    checks += 1
                    return checks > 1
                }
            )

            #expect(outcome == .deferredToPendingPush)
            #expect(SettingsAPIStub.requests(for: url).map(\.httpMethod) == ["GET"])
            #expect(NotificationSettingsSync.LocalPreferences(from: store) == before)
        }
    }

    @Test("a change made on the device while the read is out is kept, even before its pending marker is set")
    func localChangeDuringTheReadIsKept() async throws {
        try await Fixtures.withStore { store in
            Self.setDeviceValues(store)
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let url = Fixtures.documentURL(baseURL)
            SettingsAPIStub.enqueue(
                try Fixtures.found(
                    ["assignments": Self.serverAssignments(), "live_activity": Self.serverLiveActivity()],
                    revision: 2
                ),
                for: url
            )
            SettingsAPIStub.enqueue(try Fixtures.written(revision: 3), for: url)
            let client = SettingsAPIStub.makeClient(baseURL: baseURL, authHeaderProvider: {
                await MainActor.run { store.assignmentLiveActivityLeadTime = 3600 }
                return nil
            })

            let outcome = try await Self.reconcile(store, client: client)

            #expect(outcome == .deferredToPendingPush)
            #expect(SettingsAPIStub.requests(for: url).map(\.httpMethod) == ["GET"])
            #expect(store.assignmentLiveActivityLeadTime == 3600)
            #expect(store.isAssignmentReminderEnabled == false)
            #expect(store.assignmentReminderOffsets == [.hr8, .min30])
        }
    }

    @Test("a section whose device switch is off is neither adopted nor written")
    func unsyncedSectionIsLeftAlone() async throws {
        try await Fixtures.withStore { store in
            Self.setDeviceValues(store)

            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let url = Fixtures.documentURL(baseURL)
            SettingsAPIStub.enqueue(try Fixtures.found(Self.serverDocument(), revision: 1), for: url)
            SettingsAPIStub.enqueue(try Fixtures.written(revision: 2), for: url)

            let outcome = try await Self.reconcile(
                store, client: SettingsAPIStub.makeClient(baseURL: baseURL), syncLiveActivity: false
            )

            #expect(outcome == .settled(adopted: [.assignments, .courses], seeded: []))
            #expect(SettingsAPIStub.requests(for: url).map(\.httpMethod) == ["GET"])
            #expect(store.isAssignmentReminderEnabled == true)
            #expect(store.showInClassScenario == true)
            #expect(store.assignmentLiveActivityLeadTime == 5400)

            let missingBaseURL = SettingsAPIStub.uniqueBaseURL()
            let missingURL = Fixtures.documentURL(missingBaseURL)
            SettingsAPIStub.enqueue(
                try Fixtures.found(["assignments": Self.serverAssignments(), "courses": Self.serverCourses()], revision: 1),
                for: missingURL
            )
            SettingsAPIStub.enqueue(try Fixtures.written(revision: 2), for: missingURL)

            let missingOutcome = try await Self.reconcile(
                store, client: SettingsAPIStub.makeClient(baseURL: missingBaseURL), syncLiveActivity: false
            )

            #expect(missingOutcome == .settled(adopted: [.assignments, .courses], seeded: []))
            #expect(SettingsAPIStub.requests(for: missingURL).map(\.httpMethod) == ["GET"])
        }
    }

    @Test("with course sync off, nothing is requested at all")
    func nothingToSyncRequestsNothing() async throws {
        try await Fixtures.withStore { store in
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let url = Fixtures.documentURL(baseURL)
            SettingsAPIStub.enqueue(Fixtures.notFound(), for: url)
            SettingsAPIStub.enqueue(try Fixtures.written(revision: 1), for: url)

            let outcome = try await Self.reconcile(
                store, client: SettingsAPIStub.makeClient(baseURL: baseURL), cloudSyncEnabled: false
            )

            #expect(outcome == .skipped)
            #expect(SettingsAPIStub.requests(for: url).isEmpty)
        }
    }

    @Test("with both device switches off, class reminders still settle, as they have no switch")
    func bothDeviceSwitchesOffStillSettleCourses() async throws {
        try await Fixtures.withStore { store in
            Self.setDeviceValues(store)
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let url = Fixtures.documentURL(baseURL)
            SettingsAPIStub.enqueue(try Fixtures.found(["assignments": Self.serverAssignments()], revision: 2), for: url)
            SettingsAPIStub.enqueue(try Fixtures.written(revision: 3), for: url)

            let outcome = try await Self.reconcile(
                store,
                client: SettingsAPIStub.makeClient(baseURL: baseURL),
                syncAssignments: false,
                syncLiveActivity: false
            )

            #expect(outcome == .settled(adopted: [], seeded: [.courses]))
            let requests = SettingsAPIStub.requests(for: url)
            try #require(requests.map(\.httpMethod) == ["GET", "PUT"])
            let sent = try Fixtures.sentDocument(requests[1])
            #expect(Set(sent.keys) == ["assignments", "courses"])
            #expect((sent["courses"] as? [String: Any])?["enabled"] as? Bool == false)
            #expect(store.isAssignmentReminderEnabled == false)
            #expect((sent["assignments"] as? [String: Any])?["enabled"] as? Bool == true)
        }
    }

    @Test("a 409 on the write settles against the winner: what it now has is adopted, only what it lacks is written")
    func conflictSettlesAgainstTheWinner() async throws {
        try await Fixtures.withStore { store in
            Self.setDeviceValues(store)
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let url = Fixtures.documentURL(baseURL)
            SettingsAPIStub.enqueue(Fixtures.notFound(), for: url)
            SettingsAPIStub.enqueue(
                try Fixtures.conflict(
                    ["assignments": Self.serverAssignments(), "courses": Self.serverCourses()],
                    revision: 5
                ),
                for: url
            )
            SettingsAPIStub.enqueue(try Fixtures.written(revision: 6), for: url)

            let outcome = try await Self.reconcile(store, client: SettingsAPIStub.makeClient(baseURL: baseURL))

            #expect(outcome == .settled(adopted: [.assignments, .courses], seeded: [.liveActivity]))
            let requests = SettingsAPIStub.requests(for: url)
            try #require(requests.map(\.httpMethod) == ["GET", "PUT", "PUT"])
            #expect(try Fixtures.sentEnvelope(requests[2])["base_revision"] as? Int == 5)
            let retry = try Fixtures.sentDocument(requests[2])

            let assignments = try #require(retry["assignments"] as? [String: Any])
            #expect(assignments["enabled"] as? Bool == true)
            #expect(assignments["reminder_offsets_minutes"] as? [Int] == [1440, 120, 15])
            #expect(store.isAssignmentReminderEnabled == true)
            #expect(store.assignmentReminderOffsets == [.hr24, .hr2, .min15])

            #expect((retry["courses"] as? [String: Any])?["reminder_offsets_minutes"] as? [Int] == [5])
            #expect(store.isClassReminderEnabled == true)
            #expect(store.classReminderLeadMinutes == 5)

            let liveActivity = try #require(retry["live_activity"] as? [String: Any])
            #expect(liveActivity["assignment_lead_seconds"] as? Int == 5400)
        }
    }

    @Test("a malformed field keeps its local value while the fields beside it are adopted")
    func malformedFieldKeepsItsLocalValue() async throws {
        try await Fixtures.withStore { store in
            Self.setDeviceValues(store)
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let url = Fixtures.documentURL(baseURL)
            let existing: [String: Any] = [
                "assignments": ["enabled": "yes", "reminder_offsets_minutes": [60]],
                "live_activity": ["show_in_class": "no", "assignment_lead_seconds": 3600],
                "courses": ["enabled": "on", "reminder_offsets_minutes": [15]],
            ]
            SettingsAPIStub.enqueue(try Fixtures.found(existing, revision: 1), for: url)
            SettingsAPIStub.enqueue(try Fixtures.written(revision: 2), for: url)

            let outcome = try await Self.reconcile(store, client: SettingsAPIStub.makeClient(baseURL: baseURL))

            #expect(outcome == .settled(adopted: [.assignments, .liveActivity, .courses], seeded: []))
            #expect(SettingsAPIStub.requests(for: url).map(\.httpMethod) == ["GET"])
            #expect(store.isAssignmentReminderEnabled == false)
            #expect(store.assignmentReminderOffsets == [.hr1])
            #expect(store.showInClassScenario == true)
            #expect(store.assignmentLiveActivityLeadTime == 3600)
            #expect(store.isClassReminderEnabled == false)
            #expect(store.classReminderLeadMinutes == 15)
        }
    }

    @Test("sign-in reads the new account's document before any write, and adopts it instead of overwriting it")
    func signInReadsBeforeWriting() async throws {
        try await Fixtures.withStore { store in
            Self.setDeviceValues(store)

            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let url = Fixtures.documentURL(baseURL)
            SettingsAPIStub.enqueue(try Fixtures.found(Self.serverDocument(), revision: 12), for: url)
            SettingsAPIStub.enqueue(try Fixtures.written(revision: 13), for: url)

            let outcome = try await Self.reconcile(store, client: SettingsAPIStub.makeClient(baseURL: baseURL))

            #expect(SettingsAPIStub.requests(for: url).map(\.httpMethod) == ["GET"])
            #expect(outcome == .settled(adopted: [.assignments, .liveActivity, .courses], seeded: []))
            #expect(store.isAssignmentReminderEnabled == true)
            #expect(store.assignmentReminderOffsets == [.hr24, .hr2, .min15])
            #expect(store.assignmentLiveActivityLeadTime == 7200)

            let freshBaseURL = SettingsAPIStub.uniqueBaseURL()
            let freshURL = Fixtures.documentURL(freshBaseURL)
            SettingsAPIStub.enqueue(Fixtures.notFound(), for: freshURL)
            SettingsAPIStub.enqueue(try Fixtures.written(revision: 1), for: freshURL)

            _ = try await Self.reconcile(store, client: SettingsAPIStub.makeClient(baseURL: freshBaseURL))

            let freshRequests = SettingsAPIStub.requests(for: freshURL)
            try #require(freshRequests.map(\.httpMethod) == ["GET", "PUT"])
            #expect(try Fixtures.sentEnvelope(freshRequests[1])["base_revision"] is NSNull)
        }
    }

    @Test("the document a full sync already fetched is adopted without reading it again")
    func snapshotDocumentIsAdoptedWithoutARead() async throws {
        try await Fixtures.withStore { store in
            Self.setDeviceValues(store)
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let document = try JSONSerialization.data(withJSONObject: Self.serverDocument())

            let outcome = try await Self.reconcile(
                store, client: SettingsAPIStub.makeClient(baseURL: baseURL),
                source: .snapshot((document: document, revision: 7))
            )

            #expect(outcome == .settled(adopted: [.assignments, .liveActivity, .courses], seeded: []))
            #expect(SettingsAPIStub.requests(for: Fixtures.documentURL(baseURL)).isEmpty)
            #expect(store.isAssignmentReminderEnabled == true)
            #expect(store.classPreparingLeadTime == 900)
        }
    }

    @Test("a snapshot without the document seeds it with a create, and reads nothing")
    func snapshotWithoutTheDocumentSeedsIt() async throws {
        try await Fixtures.withStore { store in
            Self.setDeviceValues(store)
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let url = Fixtures.documentURL(baseURL)
            SettingsAPIStub.enqueue(try Fixtures.written(revision: 1), for: url)

            let outcome = try await Self.reconcile(
                store, client: SettingsAPIStub.makeClient(baseURL: baseURL), source: .snapshot(nil)
            )

            #expect(outcome == .settled(adopted: [], seeded: [.assignments, .liveActivity, .courses]))
            let requests = SettingsAPIStub.requests(for: url)
            try #require(requests.map(\.httpMethod) == ["PUT"])
            #expect(try Fixtures.sentEnvelope(requests[0])["base_revision"] is NSNull)
        }
    }

    @Test("a settled reconcile keeps what it settled as the synced copy, not an edit made during its write")
    func settledReconcileRecordsWhatItSettled() async throws {
        try await Fixtures.withStore { store in
            Self.setDeviceValues(store)
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let url = Fixtures.documentURL(baseURL)
            SettingsAPIStub.enqueue(
                try Fixtures.found(["assignments": Self.serverAssignments(), "courses": Self.serverCourses()], revision: 3),
                for: url
            )
            SettingsAPIStub.enqueue(try Fixtures.written(revision: 4), for: url)
            let client = SettingsAPIStub.makeClient(baseURL: baseURL, authHeaderProvider: {
                await MainActor.run {
                    if SettingsAPIStub.requests(for: url).count == 1 { store.classPreparingLeadTime = 600 }
                }
                return nil
            })
            var recorded: NotificationSettingsSync.LocalPreferences?

            let outcome = try await Self.reconcile(store, client: client, recordSynced: { recorded = $0 })

            #expect(outcome == .settled(adopted: [.assignments, .courses], seeded: [.liveActivity]))
            #expect(SettingsAPIStub.requests(for: url).map(\.httpMethod) == ["GET", "PUT"])
            #expect(store.classPreparingLeadTime == 600)
            #expect(recorded?.classPreparingLeadTime == 1800)
            #expect(recorded?.isAssignmentReminderEnabled == true)
            #expect(recorded?.classReminderLeadMinutes == 5)
        }
    }

    @Test("a snapshot gives its notification document, none, or nothing to go on")
    func documentSourceFromTheSnapshot() throws {
        let entry: [String: Any] = ["namespace": "notification", "document": ["assignments": ["enabled": true]], "revision": 7]
        guard case .snapshot(let copy?) = NotificationSettingsSync.documentSource(fromSnapshot: ["settings_documents": [entry]]) else {
            Issue.record("the snapshot's document was not used")
            return
        }
        #expect(copy.revision == 7)
        let document = try #require(try JSONSerialization.jsonObject(with: copy.document) as? [String: Any])
        #expect((document["assignments"] as? [String: Any])?["enabled"] as? Bool == true)

        guard case .snapshot(nil) = NotificationSettingsSync.documentSource(fromSnapshot: ["settings_documents": []]) else {
            Issue.record("an account without the document should be seeded")
            return
        }
        guard case .read = NotificationSettingsSync.documentSource(fromSnapshot: [:]) else {
            Issue.record("an older backend's snapshot carries no documents, so the reconcile reads")
            return
        }
    }
}
