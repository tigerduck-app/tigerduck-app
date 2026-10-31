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
                current: Self.preferences(showInClass: true), signedIn: true, storedDataReadsBack: { true }
            )
            NotificationSettingsSyncedSeedMigration.runIfNeeded(
                current: Self.preferences(showInClass: false), signedIn: true, storedDataReadsBack: { true }
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

            NotificationSettingsSyncedSeedMigration.runIfNeeded(current: local, signedIn: true, storedDataReadsBack: { true })

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

    @MainActor
    private final class ReadLog {
        private(set) var reads = 0
        func record(_ value: NotificationSettingsSync.LocalPreferences) -> NotificationSettingsSync.LocalPreferences {
            reads += 1
            return value
        }
    }

    @Test("a sign-in with no synced copy takes the device's values as the copy: an edit made while signed out gives way, one made after goes up")
    func signInStartsTheCopy() async throws {
        try await Self.withCleanState {
            var server = Self.preferences(showInClass: true)
            server.classPreparingLeadTime = 900
            let signedOut = Self.preferences(showInClass: true)

            NotificationSettingsSync.accountSignedIn(local: signedOut)

            #expect(NotificationSettingsSync.synced == signedOut)
            let edited = Self.preferences(showInClass: false)
            let base = NotificationSettingsSync.pushBase(local: edited)
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let url = NotificationSettingsFixtures.documentURL(baseURL)
            SettingsAPIStub.enqueue(
                try NotificationSettingsFixtures.found(try server.documentUpdates(existing: [:]), revision: 5),
                for: url
            )
            SettingsAPIStub.enqueue(try NotificationSettingsFixtures.written(revision: 6), for: url)

            try await NotificationSettingsSync.push(
                local: edited, base: base, client: SettingsAPIStub.makeClient(baseURL: baseURL), cloudSyncEnabled: true
            )

            let requests = SettingsAPIStub.requests(for: url)
            try #require(requests.map(\.httpMethod) == ["GET", "PUT"])
            let liveActivity = try #require(
                try NotificationSettingsFixtures.sentDocument(requests[1])["live_activity"] as? [String: Any]
            )
            #expect(liveActivity["show_in_class"] as? Bool == false)
            #expect(liveActivity["class_preparing_lead_seconds"] as? Int == 900)
        }
    }

    @Test("a sign-in keeps a copy it finds, and leaves none while the upgrade's push still sends every field")
    func signInKeepsACopyAndTheUpgradeMark() async {
        await Self.withCleanState {
            NotificationSettingsSync.synced = Self.preferences(showInClass: true)
            NotificationSettingsSync.accountSignedIn(local: Self.preferences(showInClass: false))
            #expect(NotificationSettingsSync.synced == Self.preferences(showInClass: true))

            NotificationSettingsSync.synced = nil
            Defaults[.notificationSettingsPushSendsEveryField] = true
            NotificationSettingsSync.accountSignedIn(local: Self.preferences(showInClass: false))
            #expect(NotificationSettingsSync.synced == nil)
            #expect(NotificationSettingsSync.pushBase(local: Self.preferences(showInClass: false)) == nil)
        }
    }

    @Test("an upgrade while signed out stores neither copy nor mark, so the sign-in starts the copy")
    func upgradeWhileSignedOutLeavesItToTheSignIn() async {
        await Self.withCleanState {
            Defaults[.notificationSettingsPushPending] = true

            NotificationSettingsSyncedSeedMigration.runIfNeeded(
                current: Self.preferences(showInClass: true), signedIn: false, storedDataReadsBack: { true }
            )

            #expect(NotificationSettingsSync.synced == nil)
            #expect(!Defaults[.notificationSettingsPushSendsEveryField])
            #expect(UserDefaults.standard.bool(forKey: doneKey))
        }
    }

    @Test("the migration reads the device's values only once stored data reads back")
    func readsTheValuesOnlyAfterTheGate() async {
        await Self.withCleanState {
            Defaults[.notificationSettingsPushPending] = false
            let log = ReadLog()

            NotificationSettingsSyncedSeedMigration.runIfNeeded(
                current: log.record(Self.preferences(showInClass: true)), signedIn: true, storedDataReadsBack: { false }
            )

            #expect(log.reads == 0)
        }
    }

    @Test("before stored data reads back the migration stores nothing and stays owed")
    func waitsUntilStoredDataReadsBack() async {
        await Self.withCleanState {
            Defaults[.notificationSettingsPushPending] = false

            NotificationSettingsSyncedSeedMigration.runIfNeeded(
                current: Self.preferences(showInClass: true), signedIn: true, storedDataReadsBack: { false }
            )

            #expect(NotificationSettingsSync.synced == nil)
            #expect(!UserDefaults.standard.bool(forKey: doneKey))

            NotificationSettingsSyncedSeedMigration.runIfNeeded(
                current: Self.preferences(showInClass: true), signedIn: true, storedDataReadsBack: { true }
            )

            #expect(NotificationSettingsSync.synced == Self.preferences(showInClass: true))
            #expect(UserDefaults.standard.bool(forKey: doneKey))
        }
    }
}
