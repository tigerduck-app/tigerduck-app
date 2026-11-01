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

            #expect(NotificationSettingsSync.lastSyncedPreferences == Self.preferences(showInClass: true))
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
            #expect(base == .everyField)
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
            #expect(written == .landed)
            #expect((sent["live_activity"] as? [String: Any])?["show_in_class"] as? Bool == true)

            NotificationSettingsSync.mergeSentFields(try local.documentUpdates(existing: [:]), of: local, for: testSignIn)
            #expect(NotificationSettingsSync.lastSyncedPreferences == local)
            #expect(NotificationSettingsSync.pushBase(local: Self.preferences(showInClass: false)) == .since(local))
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

            NotificationSettingsSync.seedSyncedCopyOnSignIn(from: signedOut, for: testSignIn)

            #expect(NotificationSettingsSync.lastSyncedPreferences == signedOut)
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
            NotificationSettingsSync.seedSyncedCopyOnSignIn(from: Self.preferences(showInClass: true), for: testSignIn)
            NotificationSettingsSync.seedSyncedCopyOnSignIn(from: Self.preferences(showInClass: false), for: testSignIn)
            #expect(NotificationSettingsSync.lastSyncedPreferences == Self.preferences(showInClass: true))

            NotificationSettingsSync.forget()
            Defaults[.notificationSettingsPushSendsEveryField] = true
            NotificationSettingsSync.seedSyncedCopyOnSignIn(from: Self.preferences(showInClass: false), for: testSignIn)
            #expect(NotificationSettingsSync.lastSyncedPreferences == nil)
            #expect(NotificationSettingsSync.pushBase(local: Self.preferences(showInClass: false)) == .everyField)
        }
    }

    @Test("an upgrade seed for a sign-in that has ended stores neither copy nor mark")
    func seedOfAnEndedSignInStoresNothing() async {
        await Self.withCleanState {
            NotificationSettingsSync.seedOnUpgrade(local: Self.preferences(showInClass: true), pushPending: false,
                                                   for: endedTestSignIn)
            NotificationSettingsSync.seedOnUpgrade(local: Self.preferences(showInClass: true), pushPending: true,
                                                   for: endedTestSignIn)

            #expect(NotificationSettingsSync.lastSyncedPreferences == nil)
            #expect(!Defaults[.notificationSettingsPushSendsEveryField])
        }
    }

    @Test("an upgrade while signed out stores neither copy nor mark, so the sign-in starts the copy")
    func upgradeWhileSignedOutLeavesItToTheSignIn() async {
        await Self.withCleanState {
            Defaults[.notificationSettingsPushPending] = true

            NotificationSettingsSyncedSeedMigration.runIfNeeded(
                current: Self.preferences(showInClass: true), signedIn: false, storedDataReadsBack: { true }
            )

            #expect(NotificationSettingsSync.lastSyncedPreferences == nil)
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

    @Test("a push records only the fields it sent, so a section turned back on while it was out keeps its new copy")
    func pushRecordsOnlyWhatItSent() async throws {
        try await Self.withCleanState {
            let copy = Self.preferences(showInClass: true)
            NotificationSettingsSync.seedSyncedCopyOnSignIn(from: copy, for: testSignIn)
            var startOfPush = copy
            startOfPush.isAssignmentReminderEnabled = false
            var duringPush = startOfPush
            duringPush.classPreparingLeadTime = 900
            var server = copy
            server.classPreparingLeadTime = 600
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let url = NotificationSettingsFixtures.documentURL(baseURL)
            SettingsAPIStub.enqueue(
                try NotificationSettingsFixtures.found(try server.documentUpdates(existing: [:]), revision: 1),
                for: url
            )
            SettingsAPIStub.enqueue(try NotificationSettingsFixtures.written(revision: 2), for: url)
            let client = SettingsAPIStub.makeClient(baseURL: baseURL, authHeaderProvider: {
                await MainActor.run {
                    if SettingsAPIStub.requests(for: url).count == 1 {
                        NotificationSettingsSync.sectionTurnedOn(.liveActivity, local: duringPush, for: testSignIn)
                    }
                }
                return nil
            })
            var sent: [String: Any] = [:]

            let written = try await NotificationSettingsSync.push(
                local: startOfPush,
                base: NotificationSettingsSync.pushBase(local: startOfPush),
                client: client,
                cloudSyncEnabled: true,
                syncLiveActivityEnabled: false,
                recordOnServer: { sent = $0 }
            )
            #expect(written == .landed)
            NotificationSettingsSync.mergeSentFields(sent, of: startOfPush, for: testSignIn)

            #expect(NotificationSettingsSync.lastSyncedPreferences?.classPreparingLeadTime == 900)
            #expect(NotificationSettingsSync.lastSyncedPreferences?.isAssignmentReminderEnabled == false)
            let afterFirst = try NotificationSettingsFixtures.sentDocument(SettingsAPIStub.requests(for: url)[1])
            SettingsAPIStub.enqueue(try NotificationSettingsFixtures.found(afterFirst, revision: 2), for: url)
            SettingsAPIStub.enqueue(try NotificationSettingsFixtures.written(revision: 3), for: url)

            try await NotificationSettingsSync.push(
                local: duringPush,
                base: NotificationSettingsSync.pushBase(local: duringPush),
                client: client,
                cloudSyncEnabled: true
            )

            #expect(SettingsAPIStub.requests(for: url).map(\.httpMethod) == ["GET", "PUT", "GET"])
        }
    }

    @Test("a push with nothing to write records the fields it changed, so a later change back goes up")
    func noWritePushRecordsTheFieldsItChanged() async throws {
        try await Self.withCleanState {
            NotificationSettingsSync.seedSyncedCopyOnSignIn(from: Self.preferences(showInClass: false), for: testSignIn)
            let turnedOn = Self.preferences(showInClass: true)
            let server = try turnedOn.documentUpdates(existing: [:])
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let url = NotificationSettingsFixtures.documentURL(baseURL)
            SettingsAPIStub.enqueue(try NotificationSettingsFixtures.found(server, revision: 1), for: url)
            SettingsAPIStub.enqueue(try NotificationSettingsFixtures.found(server, revision: 1), for: url)
            SettingsAPIStub.enqueue(try NotificationSettingsFixtures.written(revision: 2), for: url)
            let client = SettingsAPIStub.makeClient(baseURL: baseURL)
            var sent: [String: Any] = [:]

            let landed = try await NotificationSettingsSync.push(
                local: turnedOn,
                base: NotificationSettingsSync.pushBase(local: turnedOn),
                client: client,
                cloudSyncEnabled: true,
                recordOnServer: { sent = $0 }
            )
            #expect(landed == .landed)
            NotificationSettingsSync.mergeSentFields(sent, of: turnedOn, for: testSignIn)
            #expect(NotificationSettingsSync.lastSyncedPreferences?.showInClassScenario == true)

            let turnedOff = Self.preferences(showInClass: false)
            try await NotificationSettingsSync.push(
                local: turnedOff,
                base: NotificationSettingsSync.pushBase(local: turnedOff),
                client: client,
                cloudSyncEnabled: true
            )

            let requests = SettingsAPIStub.requests(for: url)
            try #require(requests.map(\.httpMethod) == ["GET", "GET", "PUT"])
            let written = try NotificationSettingsFixtures.sentDocument(requests[2])
            #expect((written["live_activity"] as? [String: Any])?["show_in_class"] as? Bool == false)
        }
    }

    @Test("before stored data reads back the migration stores nothing and stays owed")
    func waitsUntilStoredDataReadsBack() async {
        await Self.withCleanState {
            Defaults[.notificationSettingsPushPending] = false

            NotificationSettingsSyncedSeedMigration.runIfNeeded(
                current: Self.preferences(showInClass: true), signedIn: true, storedDataReadsBack: { false }
            )

            #expect(NotificationSettingsSync.lastSyncedPreferences == nil)
            #expect(!UserDefaults.standard.bool(forKey: doneKey))

            NotificationSettingsSyncedSeedMigration.runIfNeeded(
                current: Self.preferences(showInClass: true), signedIn: true, storedDataReadsBack: { true }
            )

            #expect(NotificationSettingsSync.lastSyncedPreferences == Self.preferences(showInClass: true))
            #expect(UserDefaults.standard.bool(forKey: doneKey))
        }
    }
}
