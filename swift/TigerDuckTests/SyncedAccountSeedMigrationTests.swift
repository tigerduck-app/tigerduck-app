// Runs on the real `Defaults` keys inside `withExclusiveRealDefaults`. `doneKey` mirrors the
// migration's private flag literal, and is restored as present or absent, because the migration
// reads an absent one as "not run yet".
import Defaults
import Foundation
import Testing
@testable import TigerDuck

private let doneKey = "SyncedAccountSeedMigration.v1.done"

/// `SyncedAccountSeedMigration`: which installs keep the re-enable check after the update, before
/// a full sync has recorded the account on this version.
@MainActor
struct SyncedAccountSeedMigrationTests {
    private static let categories: Set<String> = ["courses", "course_colors", "course_names", "assignments"]

    /// As 2.3.0 leaves an install: the migration not run yet, and no sync recorded.
    private static func withUpdatedInstall(_ body: () -> Void) async {
        await withExclusiveRealDefaults {
            let saved = (
                Defaults[.accountSyncedOnce], Defaults[.lastSeenCoursesResetAt],
                Defaults[.pendingConflictCategories]
            )
            let savedDone = UserDefaults.standard.object(forKey: doneKey)
            defer {
                Defaults[.accountSyncedOnce] = saved.0
                Defaults[.lastSeenCoursesResetAt] = saved.1
                Defaults[.pendingConflictCategories] = saved.2
                if let savedDone {
                    UserDefaults.standard.set(savedDone, forKey: doneKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: doneKey)
                }
            }
            UserDefaults.standard.removeObject(forKey: doneKey)
            Defaults[.accountSyncedOnce] = false
            Defaults[.lastSeenCoursesResetAt] = nil
            Defaults[.pendingConflictCategories] = []
            body()
        }
    }

    @Test("An install signed in at the update counts as synced, and only that launch decides")
    func signedInAtTheUpdateCountsAsSyncedOnce() async {
        await Self.withUpdatedInstall {
            SyncedAccountSeedMigration.runIfNeeded(signedIn: true)

            #expect(AppState.hasSyncedAccount)

            // As a sign-out leaves it: a later launch must not count the next account as synced.
            Defaults[.accountSyncedOnce] = false
            SyncedAccountSeedMigration.runIfNeeded(signedIn: true)

            #expect(!AppState.hasSyncedAccount)
        }
    }

    @Test("An install signed out at the update, as a fresh install reads, does not count as synced after a later sign-in either")
    func signedOutAtTheUpdateDoesNotCountAsSynced() async {
        await Self.withUpdatedInstall {
            SyncedAccountSeedMigration.runIfNeeded(signedIn: false)

            #expect(!AppState.hasSyncedAccount)

            // The next launch, signed in on this version.
            SyncedAccountSeedMigration.runIfNeeded(signedIn: true)

            #expect(!AppState.hasSyncedAccount)
        }
    }

    @Test("Turning TigerSync back on before the first sync since the update checks every category of an account signed in at the update")
    func signedInAtTheUpdateKeepsTheReenableCheck() async {
        await Self.withUpdatedInstall {
            SyncedAccountSeedMigration.runIfNeeded(signedIn: true)

            for category in Self.categories { AppState.markForReenableCheck(category, signedIn: true) }

            #expect(Defaults[.pendingConflictCategories] == Self.categories)
        }
    }
}
