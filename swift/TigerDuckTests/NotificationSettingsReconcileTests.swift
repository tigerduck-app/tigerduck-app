// `NotificationSettingsSync.reconcile` — the one routine that reads the
// `notification` settings document — against a real
// `LiveActivityPreferencesStore`, through the real `SettingsDocumentClient`
// and `SettingsAPIStub`.
//
// Pins, for each section this device syncs:
//
//   1. no document at all: every synced section is written from the
//      device's own values — reminders switched off included — as a
//      create. This is an upgrading 2.0.x user's first run; until it lands
//      the backend falls back to its own defaults.
//   2. the section is on the server: it is adopted, and nothing is written.
//   3. a partial document: the present section is adopted, only the missing
//      one written, and every other key survives.
//   4. a local edit still waiting to go up wins, whether it was there
//      before the read or lands during it.
//   5. a section whose device switch is off is neither adopted nor
//      written; with nothing to sync nothing is requested at all.
//   6. a 409 on the write settles against the winner and retries once.
//   7. a malformed field keeps its local value; the fields beside it are
//      adopted.
//   8. sign-in reads the new account's document before any write.
//
// The logout guard is pinned with the queue it belongs to
// (`NotificationSettingsPushQueueTests`), the once-after-upgrade trigger in
// `NotificationSettingsSeedMigrationTests`.
//
// Where a regression would send a request the test does not expect, a
// response for it is queued anyway, so the regression fails an assertion
// below instead of surfacing as a transport error.
//
// `.serialized`, `@MainActor` and Defaults-restoring for the same reasons as
// `NotificationSettingsApplyTests`.
import Defaults
import Foundation
import Testing
@testable import TigerDuck

@Suite("Notification settings reconcile", .serialized)
@MainActor
struct NotificationSettingsReconcileTests {
    private typealias Fixtures = NotificationSettingsFixtures

    // MARK: - Fixtures

    /// What a 2.0.x user who switched reminders off and trimmed the offsets
    /// holds on the device.
    private static func setDeviceValues(_ store: LiveActivityPreferencesStore) {
        store.isAssignmentReminderEnabled = false
        store.assignmentReminderOffsets = [.hr8, .min30]
        store.showClassPreparingScenario = false
        store.showInClassScenario = true
        store.showAssignmentScenario = true
        store.classPreparingLeadTime = 1800
        store.assignmentLiveActivityLeadTime = 5400
    }

    /// Server sections that differ from `setDeviceValues` in every field.
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

    private static func reconcile(
        _ store: LiveActivityPreferencesStore,
        client: SettingsDocumentClient,
        cloudSyncEnabled: Bool = true,
        syncAssignments: Bool = true,
        syncLiveActivity: Bool = true,
        isPushPending: () -> Bool = { false }
    ) async throws -> NotificationSettingsSync.ReconcileOutcome {
        try await NotificationSettingsSync.reconcile(
            store: store,
            client: client,
            cloudSyncEnabled: cloudSyncEnabled,
            syncAssignmentRemindersEnabled: syncAssignments,
            syncLiveActivityEnabled: syncLiveActivity,
            isPushPending: isPushPending
        )
    }

    // MARK: - 1. No document: seed from the device

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

            #expect(outcome == .settled(adopted: [], seeded: [.assignments, .liveActivity]))
            let requests = SettingsAPIStub.requests(for: url)
            try #require(requests.map(\.httpMethod) == ["GET", "PUT"])
            // A create: there was no document to compare-and-swap against.
            #expect(try Fixtures.sentEnvelope(requests[1])["base_revision"] is NSNull)
            let document = try Fixtures.sentDocument(requests[1])
            #expect(Set(document.keys) == ["assignments", "live_activity"])

            // Off on the device, so off on the server. Left unseeded, the
            // backend reads a missing document as "reminders on".
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

            // Seeding never changes the device itself.
            #expect(NotificationSettingsSync.LocalPreferences(from: store) == before)
        }
    }

    // MARK: - 2 and 3. Present sections are adopted, only missing ones written

    @Test("the server has both sections: both are adopted, field by field, and nothing is written")
    func presentDocumentIsAdoptedAndNothingWritten() async throws {
        try await Fixtures.withStore { store in
            Self.setDeviceValues(store)
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let url = Fixtures.documentURL(baseURL)
            SettingsAPIStub.enqueue(
                try Fixtures.found(
                    ["assignments": Self.serverAssignments(), "live_activity": Self.serverLiveActivity()],
                    revision: 7
                ),
                for: url
            )
            SettingsAPIStub.enqueue(try Fixtures.written(revision: 8), for: url)

            let outcome = try await Self.reconcile(store, client: SettingsAPIStub.makeClient(baseURL: baseURL))

            #expect(outcome == .settled(adopted: [.assignments, .liveActivity], seeded: []))
            #expect(SettingsAPIStub.requests(for: url).map(\.httpMethod) == ["GET"])
            #expect(store.isAssignmentReminderEnabled == true)
            #expect(store.assignmentReminderOffsets == [.hr24, .hr2, .min15])
            #expect(store.showClassPreparingScenario == true)
            #expect(store.showInClassScenario == false)
            #expect(store.showAssignmentScenario == false)
            #expect(store.classPreparingLeadTime == 900)
            #expect(store.assignmentLiveActivityLeadTime == 7200)
        }
    }

    @Test("the server has one section: it is adopted, only the other is written, and every other key survives")
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

            #expect(outcome == .settled(adopted: [.assignments], seeded: [.liveActivity]))
            let requests = SettingsAPIStub.requests(for: url)
            try #require(requests.map(\.httpMethod) == ["GET", "PUT"])
            #expect(try Fixtures.sentEnvelope(requests[1])["base_revision"] as? Int == 3)
            let sent = try Fixtures.sentDocument(requests[1])

            // The server's assignments are adopted, and go back untouched.
            #expect(store.isAssignmentReminderEnabled == true)
            #expect(store.assignmentReminderOffsets == [.hr24, .hr2, .min15])
            let assignments = try #require(sent["assignments"] as? [String: Any])
            #expect(assignments["enabled"] as? Bool == true)
            #expect(assignments["reminder_offsets_minutes"] as? [Int] == [1440, 120, 15])
            #expect(assignments["reminder_offsets_hours"] as? [Int] == [24, 2])

            // The missing section is written from the device, which keeps it.
            let liveActivity = try #require(sent["live_activity"] as? [String: Any])
            #expect(liveActivity["show_class_preparing"] as? Bool == false)
            #expect(liveActivity["class_preparing_lead_seconds"] as? Int == 1800)
            #expect(liveActivity["assignment_lead_seconds"] as? Int == 5400)
            #expect(store.showInClassScenario == true)
            #expect(store.assignmentLiveActivityLeadTime == 5400)

            // Keys this app does not own survive the write.
            #expect((sent["courses"] as? [String: Any])?["reminder_offsets_minutes"] as? [Int] == [10])
            #expect((sent["future_section"] as? [String: Any])?["x"] as? Int == 1)
        }
    }

    // MARK: - 4. A pending local edit wins

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

            // Clear when the read goes out, set by the time it comes back.
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
            // The user moves a slider while the GET is out. The client asks
            // for its auth header right before sending, which is as close to
            // mid-request as the stub lets a test get.
            let client = SettingsAPIStub.makeClient(baseURL: baseURL, authHeaderProvider: {
                await MainActor.run { store.assignmentLiveActivityLeadTime = 3600 }
                return nil
            })

            let outcome = try await Self.reconcile(store, client: client)

            #expect(outcome == .deferredToPendingPush)
            #expect(SettingsAPIStub.requests(for: url).map(\.httpMethod) == ["GET"])
            // The user's value, not the server's 7200 — and nothing else
            // from the server either.
            #expect(store.assignmentLiveActivityLeadTime == 3600)
            #expect(store.isAssignmentReminderEnabled == false)
            #expect(store.assignmentReminderOffsets == [.hr8, .min30])
        }
    }

    // MARK: - 5. Only synced sections, and only with sync on

    @Test("a section whose device switch is off is neither adopted nor written")
    func unsyncedSectionIsLeftAlone() async throws {
        try await Fixtures.withStore { store in
            Self.setDeviceValues(store)

            // The server has both; `live_activity` does not sync here.
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let url = Fixtures.documentURL(baseURL)
            SettingsAPIStub.enqueue(
                try Fixtures.found(
                    ["assignments": Self.serverAssignments(), "live_activity": Self.serverLiveActivity()],
                    revision: 1
                ),
                for: url
            )
            SettingsAPIStub.enqueue(try Fixtures.written(revision: 2), for: url)

            let outcome = try await Self.reconcile(
                store, client: SettingsAPIStub.makeClient(baseURL: baseURL), syncLiveActivity: false
            )

            #expect(outcome == .settled(adopted: [.assignments], seeded: []))
            #expect(SettingsAPIStub.requests(for: url).map(\.httpMethod) == ["GET"])
            #expect(store.isAssignmentReminderEnabled == true)
            #expect(store.showInClassScenario == true)
            #expect(store.assignmentLiveActivityLeadTime == 5400)

            // Missing from the server, it is not written either.
            let missingBaseURL = SettingsAPIStub.uniqueBaseURL()
            let missingURL = Fixtures.documentURL(missingBaseURL)
            SettingsAPIStub.enqueue(try Fixtures.found(["assignments": Self.serverAssignments()], revision: 1), for: missingURL)
            SettingsAPIStub.enqueue(try Fixtures.written(revision: 2), for: missingURL)

            let missingOutcome = try await Self.reconcile(
                store, client: SettingsAPIStub.makeClient(baseURL: missingBaseURL), syncLiveActivity: false
            )

            #expect(missingOutcome == .settled(adopted: [.assignments], seeded: []))
            #expect(SettingsAPIStub.requests(for: missingURL).map(\.httpMethod) == ["GET"])
        }
    }

    @Test("with course sync off, or both device switches off, nothing is requested at all")
    func nothingToSyncRequestsNothing() async throws {
        try await Fixtures.withStore { store in
            let cases: [(cloudSync: Bool, assignments: Bool, liveActivity: Bool)] = [
                (false, true, true),
                (true, false, false),
            ]
            for switches in cases {
                let baseURL = SettingsAPIStub.uniqueBaseURL()
                let url = Fixtures.documentURL(baseURL)
                SettingsAPIStub.enqueue(Fixtures.notFound(), for: url)
                SettingsAPIStub.enqueue(try Fixtures.written(revision: 1), for: url)

                let outcome = try await Self.reconcile(
                    store,
                    client: SettingsAPIStub.makeClient(baseURL: baseURL),
                    cloudSyncEnabled: switches.cloudSync,
                    syncAssignments: switches.assignments,
                    syncLiveActivity: switches.liveActivity
                )

                #expect(outcome == .skipped)
                #expect(SettingsAPIStub.requests(for: url).isEmpty)
            }
        }
    }

    // MARK: - 6. Another device wrote first

    @Test("a 409 on the write settles against the winner: what it now has is adopted, only what it lacks is written")
    func conflictSettlesAgainstTheWinner() async throws {
        try await Fixtures.withStore { store in
            Self.setDeviceValues(store)
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let url = Fixtures.documentURL(baseURL)
            // No document when this device read it; another device created
            // one before this write landed.
            SettingsAPIStub.enqueue(Fixtures.notFound(), for: url)
            SettingsAPIStub.enqueue(
                try Fixtures.conflict(
                    ["assignments": Self.serverAssignments(), "courses": ["enabled": false]],
                    revision: 5
                ),
                for: url
            )
            SettingsAPIStub.enqueue(try Fixtures.written(revision: 6), for: url)

            let outcome = try await Self.reconcile(store, client: SettingsAPIStub.makeClient(baseURL: baseURL))

            #expect(outcome == .settled(adopted: [.assignments], seeded: [.liveActivity]))
            let requests = SettingsAPIStub.requests(for: url)
            try #require(requests.map(\.httpMethod) == ["GET", "PUT", "PUT"])
            #expect(try Fixtures.sentEnvelope(requests[2])["base_revision"] as? Int == 5)
            let retry = try Fixtures.sentDocument(requests[2])

            // The winner's assignments stand: adopted here, not overwritten.
            let assignments = try #require(retry["assignments"] as? [String: Any])
            #expect(assignments["enabled"] as? Bool == true)
            #expect(assignments["reminder_offsets_minutes"] as? [Int] == [1440, 120, 15])
            #expect(store.isAssignmentReminderEnabled == true)
            #expect(store.assignmentReminderOffsets == [.hr24, .hr2, .min15])

            // What it still lacks comes from the device.
            let liveActivity = try #require(retry["live_activity"] as? [String: Any])
            #expect(liveActivity["assignment_lead_seconds"] as? Int == 5400)
            #expect((retry["courses"] as? [String: Any])?["enabled"] as? Bool == false)
        }
    }

    // MARK: - 7. A malformed field

    @Test("a malformed field keeps its local value while the fields beside it are adopted")
    func malformedFieldKeepsItsLocalValue() async throws {
        try await Fixtures.withStore { store in
            Self.setDeviceValues(store)
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let url = Fixtures.documentURL(baseURL)
            let existing: [String: Any] = [
                "assignments": ["enabled": "yes", "reminder_offsets_minutes": [60]],
                "live_activity": ["show_in_class": "no", "assignment_lead_seconds": 3600],
            ]
            SettingsAPIStub.enqueue(try Fixtures.found(existing, revision: 1), for: url)
            SettingsAPIStub.enqueue(try Fixtures.written(revision: 2), for: url)

            let outcome = try await Self.reconcile(store, client: SettingsAPIStub.makeClient(baseURL: baseURL))

            // Both sections are there, readable or not, so neither is
            // written over.
            #expect(outcome == .settled(adopted: [.assignments, .liveActivity], seeded: []))
            #expect(SettingsAPIStub.requests(for: url).map(\.httpMethod) == ["GET"])
            #expect(store.isAssignmentReminderEnabled == false)
            #expect(store.assignmentReminderOffsets == [.hr1])
            #expect(store.showInClassScenario == true)
            #expect(store.assignmentLiveActivityLeadTime == 3600)
        }
    }

    // MARK: - 8. Sign-in

    @Test("sign-in reads the new account's document before any write, and adopts it instead of overwriting it")
    func signInReadsBeforeWriting() async throws {
        try await Fixtures.withStore { store in
            // The device still holds what the previous account left on it.
            Self.setDeviceValues(store)

            // The new account already has settings, from its other devices.
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let url = Fixtures.documentURL(baseURL)
            SettingsAPIStub.enqueue(
                try Fixtures.found(
                    ["assignments": Self.serverAssignments(), "live_activity": Self.serverLiveActivity()],
                    revision: 12
                ),
                for: url
            )
            SettingsAPIStub.enqueue(try Fixtures.written(revision: 13), for: url)

            let outcome = try await Self.reconcile(store, client: SettingsAPIStub.makeClient(baseURL: baseURL))

            #expect(SettingsAPIStub.requests(for: url).map(\.httpMethod) == ["GET"])
            #expect(outcome == .settled(adopted: [.assignments, .liveActivity], seeded: []))
            #expect(store.isAssignmentReminderEnabled == true)
            #expect(store.assignmentReminderOffsets == [.hr24, .hr2, .min15])
            #expect(store.assignmentLiveActivityLeadTime == 7200)

            // An account with nothing saved yet is read first too, and only
            // then created.
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
}
