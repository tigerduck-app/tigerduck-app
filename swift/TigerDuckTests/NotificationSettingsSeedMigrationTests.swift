// `NotificationSettingsSeedMigration` — the once-after-upgrade trigger for
// the notification settings routine.
//
//   1. An upgrade with no document on the server seeds it from the device's
//      own values, reminders switched off included.
//   2. An upgrade where another device already wrote the document adopts it
//      and writes nothing.
//   3. The done flag is set only once the routine reports the document
//      settled, so an upgrade whose first launch is offline, signed out or
//      has course sync off tries again on the next.
//   4. Once done, it never runs the routine again.
//
// 1 and 2 run the real routine (`NotificationSettingsSync.reconcile`)
// through `SettingsAPIStub`, handing it the same `onSettled` the app's
// wrapper does (`AppState.reconcileNotificationSettings`); nothing in this
// target constructs a full `AppState`.
//
// `doneKey` mirrors the migration's private flag literal, the way
// `PendingReminderPurgeMigrationTests` mirrors its own. `.serialized`, and
// every test clears the key first, because the flag lives in real,
// process-wide `UserDefaults.standard`.
import Defaults
import Foundation
import Testing
@testable import TigerDuck

private let doneKey = "NotificationSettingsSeedMigration.v1.done"

@Suite("Notification settings seed migration", .serialized)
@MainActor
struct NotificationSettingsSeedMigrationTests {
    private typealias Fixtures = NotificationSettingsFixtures

    init() {
        UserDefaults.standard.removeObject(forKey: doneKey)
    }

    /// Runs the migration the way the app does, with the real routine
    /// standing in for `AppState.reconcileNotificationSettings`.
    private static func runMigration(
        store: LiveActivityPreferencesStore,
        client: SettingsDocumentClient
    ) async {
        var work: Task<Void, Never>?
        NotificationSettingsSeedMigration.runIfNeeded { onSettled in
            work = Task { @MainActor in
                let outcome = try? await NotificationSettingsSync.reconcile(
                    store: store,
                    client: client,
                    cloudSyncEnabled: true,
                    syncAssignmentRemindersEnabled: true,
                    syncLiveActivityEnabled: true,
                    isPushPending: { false }
                )
                if case .settled? = outcome { onSettled() }
            }
        }
        await work?.value
    }

    @Test("an upgrade with no document seeds it from the device's values, reminders switched off included")
    func upgradeWithNoDocumentSeedsIt() async throws {
        try await Fixtures.withStore { store in
            // A 2.0.x user who switched reminders off.
            store.isAssignmentReminderEnabled = false
            store.assignmentReminderOffsets = [.hr48, .hr2, .min10]
            store.showClassPreparingScenario = true
            store.showInClassScenario = false
            store.showAssignmentScenario = true
            store.classPreparingLeadTime = 2700
            store.assignmentLiveActivityLeadTime = 10800
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let url = Fixtures.documentURL(baseURL)
            SettingsAPIStub.enqueue(Fixtures.notFound(), for: url)
            SettingsAPIStub.enqueue(try Fixtures.written(revision: 1), for: url)

            await Self.runMigration(store: store, client: SettingsAPIStub.makeClient(baseURL: baseURL))

            let requests = SettingsAPIStub.requests(for: url)
            try #require(requests.map(\.httpMethod) == ["GET", "PUT"])
            let document = try Fixtures.sentDocument(requests[1])
            let assignments = try #require(document["assignments"] as? [String: Any])
            #expect(assignments["enabled"] as? Bool == false)
            #expect(assignments["reminder_offsets_minutes"] as? [Int] == [2880, 120, 10])
            let liveActivity = try #require(document["live_activity"] as? [String: Any])
            #expect(liveActivity["show_in_class"] as? Bool == false)
            #expect(liveActivity["class_preparing_lead_seconds"] as? Int == 2700)
            #expect(liveActivity["assignment_lead_seconds"] as? Int == 10800)
            #expect(UserDefaults.standard.bool(forKey: doneKey))
        }
    }

    @Test("an upgrade where another device already wrote the document adopts it and writes nothing")
    func upgradeWithADocumentAdoptsIt() async throws {
        try await Fixtures.withStore { store in
            store.isAssignmentReminderEnabled = false
            store.assignmentReminderOffsets = [.hr48]
            store.showInClassScenario = true
            store.assignmentLiveActivityLeadTime = 10800
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let url = Fixtures.documentURL(baseURL)
            SettingsAPIStub.enqueue(
                try Fixtures.found(
                    [
                        "assignments": ["enabled": true, "reminder_offsets_minutes": [240, 60]],
                        "live_activity": ["show_in_class": false, "assignment_lead_seconds": 3600],
                    ],
                    revision: 4
                ),
                for: url
            )
            // Served only if a write went out anyway.
            SettingsAPIStub.enqueue(try Fixtures.written(revision: 5), for: url)

            await Self.runMigration(store: store, client: SettingsAPIStub.makeClient(baseURL: baseURL))

            #expect(SettingsAPIStub.requests(for: url).map(\.httpMethod) == ["GET"])
            #expect(store.isAssignmentReminderEnabled == true)
            #expect(store.assignmentReminderOffsets == [.hr4, .hr1])
            #expect(store.showInClassScenario == false)
            #expect(store.assignmentLiveActivityLeadTime == 3600)
            #expect(UserDefaults.standard.bool(forKey: doneKey))
        }
    }

    @Test("an upgrade whose routine does not settle is not marked done, and runs again next launch")
    func unsettledUpgradeRunsAgain() {
        var runs = 0
        // Offline, signed out or course sync off: the routine never settles.
        NotificationSettingsSeedMigration.runIfNeeded { _ in runs += 1 }
        NotificationSettingsSeedMigration.runIfNeeded { _ in runs += 1 }

        #expect(runs == 2)
        #expect(UserDefaults.standard.bool(forKey: doneKey) == false)
    }

    @Test("once the document has settled, the migration never runs the routine again")
    func settledUpgradeNeverRunsAgain() {
        var runs = 0
        NotificationSettingsSeedMigration.runIfNeeded { onSettled in
            runs += 1
            onSettled()
        }
        NotificationSettingsSeedMigration.runIfNeeded { onSettled in
            runs += 1
            onSettled()
        }

        #expect(runs == 1)
        #expect(UserDefaults.standard.bool(forKey: doneKey))
    }
}
