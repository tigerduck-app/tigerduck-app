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
            defer {
                UserDefaults.standard.set(savedDone, forKey: doneKey)
                Defaults[.notificationSettingsPushPending] = savedPending
                Defaults[.notificationSettingsSyncedPreferences] = savedCopy
            }
            UserDefaults.standard.removeObject(forKey: doneKey)
            Defaults[.notificationSettingsSyncedPreferences] = nil
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

            NotificationSettingsSyncedSeedMigration.runIfNeeded(current: Self.preferences(showInClass: true))
            NotificationSettingsSyncedSeedMigration.runIfNeeded(current: Self.preferences(showInClass: false))

            #expect(NotificationSettingsSync.synced == Self.preferences(showInClass: true))
            #expect(UserDefaults.standard.bool(forKey: doneKey))
        }
    }

    @Test("an upgrade with a push pending stores no copy, as the device's values hold an unsent edit")
    func upgradeWithAPendingPushStoresNoCopy() async {
        await Self.withCleanState {
            Defaults[.notificationSettingsPushPending] = true

            NotificationSettingsSyncedSeedMigration.runIfNeeded(current: Self.preferences(showInClass: true))

            #expect(NotificationSettingsSync.synced == nil)
            #expect(UserDefaults.standard.bool(forKey: doneKey))
        }
    }
}
