import Defaults
import Foundation
import Testing
@testable import TigerDuck

private let doneKey = "NotificationSettingsSyncedSeedMigration.v1.done"

@Suite("Notification settings synced copy seed migration", .serialized)
@MainActor
struct NotificationSettingsSyncedSeedMigrationTests {
    private static func withCleanState(_ body: () async throws -> Void) async rethrows {
        try await withExclusiveRealDefaults {
            let savedDone = UserDefaults.standard.object(forKey: doneKey)
            let savedPending = Defaults[.notificationSettingsPushPending]
            let savedCopy = Defaults[.notificationSettingsSyncedPreferences]
            let savedEveryField = Defaults[.notificationSettingsPushSendsEveryField]
            defer {
                UserDefaults.standard.set(savedDone, forKey: doneKey)
                Defaults[.notificationSettingsPushPending] = savedPending
                Defaults[.notificationSettingsSyncedPreferences] = savedCopy
                Defaults[.notificationSettingsPushSendsEveryField] = savedEveryField
            }
            UserDefaults.standard.removeObject(forKey: doneKey)
            Defaults[.notificationSettingsSyncedPreferences] = nil
            Defaults[.notificationSettingsPushSendsEveryField] = false
            try await body()
        }
    }

    private static func preferences(showInClass: Bool) -> NotificationSettingsSync.LocalPreferences {
        .init(
            isAssignmentReminderEnabled: true,
            assignmentReminderOffsets: [.hr24, .min30],
            showClassPreparingScenario: true,
            showInClassScenario: showInClass,
            showAssignmentScenario: false,
            classPreparingLeadTime: 1800,
            assignmentLiveActivityLeadTime: 7200,
            isClassReminderEnabled: true,
            classReminderLeadMinutes: 15,
            hasPickedClassReminderLead: true
        )
    }

    @Test("an upgrade with no push pending takes the device's values as the synced copy, once")
    func upgradeWithNothingPendingSeedsTheCopy() async {
        await Self.withCleanState {
            Defaults[.notificationSettingsPushPending] = false

            NotificationSettingsSyncedSeedMigration.runIfNeeded(
                current: Self.preferences(showInClass: true), storedDataReadsBack: { true }
            )
            NotificationSettingsSyncedSeedMigration.runIfNeeded(
                current: Self.preferences(showInClass: false), storedDataReadsBack: { true }
            )

            #expect(NotificationSettingsSync.synced == Self.preferences(showInClass: true))
            #expect(UserDefaults.standard.bool(forKey: doneKey))
        }
    }

    @Test("an edit left unsent at the upgrade goes up whole, and the push that lands records the copy")
    func editUnsentAtTheUpgradeGoesUp() async throws {
        try await Self.withCleanState {
            Defaults[.notificationSettingsPushPending] = true
            let local = Self.preferences(showInClass: true)

            NotificationSettingsSyncedSeedMigration.runIfNeeded(current: local, storedDataReadsBack: { true })

            #expect(UserDefaults.standard.bool(forKey: doneKey))
            let base = NotificationSettingsSync.pushBase(local: local)
            #expect(base == nil)
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let url = NotificationSettingsFixtures.documentURL(baseURL)
            SettingsAPIStub.enqueue(
                try NotificationSettingsFixtures.found(["live_activity": ["show_in_class": false]], revision: 3),
                for: url
            )
            SettingsAPIStub.enqueue(try NotificationSettingsFixtures.written(revision: 4), for: url)

            let written = try await NotificationSettingsSync.push(
                local: local, base: base, client: SettingsAPIStub.makeClient(baseURL: baseURL), cloudSyncEnabled: true
            )
            let sent = try NotificationSettingsFixtures.sentDocument(SettingsAPIStub.requests(for: url)[1])
            #expect(written)
            #expect((sent["live_activity"] as? [String: Any])?["show_in_class"] as? Bool == true)

            NotificationSettingsSync.recordPushed(local)
            #expect(NotificationSettingsSync.synced == local)
            #expect(NotificationSettingsSync.pushBase(local: Self.preferences(showInClass: false)) == local)
        }
    }

    @Test("with no copy and no upgrade owed, as after a sign-out, a push counts nothing as changed")
    func noCopyAfterSignOutChangesNothing() async {
        await Self.withCleanState {
            let local = Self.preferences(showInClass: true)

            #expect(NotificationSettingsSync.pushBase(local: local) == local)
        }
    }

    @Test("before stored data reads back the migration stores nothing and stays owed")
    func waitsUntilStoredDataReadsBack() async {
        await Self.withCleanState {
            Defaults[.notificationSettingsPushPending] = false

            NotificationSettingsSyncedSeedMigration.runIfNeeded(
                current: Self.preferences(showInClass: true), storedDataReadsBack: { false }
            )

            #expect(NotificationSettingsSync.synced == nil)
            #expect(!UserDefaults.standard.bool(forKey: doneKey))

            NotificationSettingsSyncedSeedMigration.runIfNeeded(
                current: Self.preferences(showInClass: true), storedDataReadsBack: { true }
            )

            #expect(NotificationSettingsSync.synced == Self.preferences(showInClass: true))
            #expect(UserDefaults.standard.bool(forKey: doneKey))
        }
    }
}
