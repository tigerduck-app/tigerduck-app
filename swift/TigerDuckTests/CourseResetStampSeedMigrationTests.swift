// Runs on the real `Defaults` keys inside `withExclusiveRealDefaults`. `doneKey` and `legacyKey`
// mirror the migration's private literals, and are restored as present or absent, because the
// migration reads an absent flag as "not run yet".
import Defaults
import Foundation
import Testing
@testable import TigerDuck

private let doneKey = "CourseResetStampSeedMigration.v1.done"
private let legacyKey = "lastCourseSyncAt"

/// `CourseResetStampSeedMigration`: a full course reset another device made after this one last
/// synced on 2.3.0 or earlier reaches the first full sync since the update as a new one.
@MainActor
struct CourseResetStampSeedMigrationTests {
    private static let lastOldSync = Date(timeIntervalSince1970: 1_790_000_000)

    /// As the update leaves an install signed in on 2.3.0: the clock of its last full sync there,
    /// no reset read on this version, and every category recorded as synced for the account.
    private static func withUpdatedInstall(_ body: () -> Void) async {
        await withExclusiveRealDefaults {
            let saved = (Defaults[.lastSeenCoursesResetAt], Defaults[.categoriesSyncedOnce])
            let savedDone = UserDefaults.standard.object(forKey: doneKey)
            let savedLegacy = UserDefaults.standard.object(forKey: legacyKey)
            defer {
                Defaults[.lastSeenCoursesResetAt] = saved.0
                Defaults[.categoriesSyncedOnce] = saved.1
                UserDefaults.standard.set(savedDone, forKey: doneKey)
                UserDefaults.standard.set(savedLegacy, forKey: legacyKey)
            }
            UserDefaults.standard.removeObject(forKey: doneKey)
            UserDefaults.standard.set(lastOldSync, forKey: legacyKey)
            Defaults[.lastSeenCoursesResetAt] = nil
            Defaults[.categoriesSyncedOnce] = AppState.reenableCategories
            body()
        }
    }

    private static func appliesReset(at reset: Date) -> Bool {
        AppState.coursesReset(server: reset, lastSeen: Defaults[.lastSeenCoursesResetAt]).apply
    }

    @Test("A reset made after this device's last sync on the old version is applied, one made before it is not")
    func aResetSinceTheLastOldSyncIsApplied() async {
        await Self.withUpdatedInstall {
            CourseResetStampSeedMigration.runIfNeeded()

            #expect(Self.appliesReset(at: Self.lastOldSync.addingTimeInterval(60)))
            #expect(!Self.appliesReset(at: Self.lastOldSync.addingTimeInterval(-60)))
            #expect(UserDefaults.standard.object(forKey: legacyKey) == nil)
        }
    }

    /// The old versions never cleared their stamp at a sign-out, so it may be another account's.
    @Test("An account this device has not synced, as after a sign-out, keeps the first sync's rule and drops the stamp")
    func anAccountWithoutSyncsHereOnlyRecordsTheReset() async {
        await Self.withUpdatedInstall {
            Defaults[.categoriesSyncedOnce] = []

            CourseResetStampSeedMigration.runIfNeeded()

            #expect(!Self.appliesReset(at: Self.lastOldSync.addingTimeInterval(60)))
            #expect(UserDefaults.standard.object(forKey: legacyKey) == nil)
        }
    }

    @Test("A reset a sync on this version read stays the one compared")
    func aResetReadOnThisVersionIsKept() async {
        await Self.withUpdatedInstall {
            let read = Self.lastOldSync.addingTimeInterval(3_600)
            Defaults[.lastSeenCoursesResetAt] = read

            CourseResetStampSeedMigration.runIfNeeded()

            #expect(Defaults[.lastSeenCoursesResetAt] == read)
        }
    }
}
