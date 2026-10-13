import Defaults
import Testing
@testable import TigerDuck

/// `syncOverridesFromBackend` writes marks, course colours and names, holiday choices and
/// manual courses after its awaits, and the re-enable conflict check shows a dialog after its
/// fetch. Sign-out clears those caches and moves the login generation in between, so the rule
/// checked after each await is pinned here.
struct FullSyncSignOutTests {
    @Test("A sync the sign-in and the sync switch both outlived may write")
    func syncThatOutlivedNothingMayWrite() {
        #expect(AppState.fullSyncMayWrite(startedIn: 4, current: 4, cloudSyncEnabled: true))
    }

    @Test("A sign-out while the sync was in flight stops its writes, even after the next sign-in")
    func signOutDuringTheSyncStopsItsWrites() {
        #expect(!AppState.fullSyncMayWrite(startedIn: 4, current: 5, cloudSyncEnabled: true))
    }

    @Test("Turning Sync course information off while the sync was in flight stops its writes")
    func syncSwitchedOffDuringTheSyncStopsItsWrites() {
        #expect(!AppState.fullSyncMayWrite(startedIn: 4, current: 4, cloudSyncEnabled: false))
    }
}

/// `AppState.categoriesLeftToCheck`: what a re-enable check leaves to another when it ends. One runs
/// at a time, so a category switched back on meanwhile waits for it. A check the sign-out outlived
/// drops its result by the rule above, and must neither strand the next account's categories nor
/// check the departing account's again on the next account's data.
@MainActor
struct ReenableCheckSignOutTests {
    @Test("A check that ends under the same sign-in leaves the categories switched back on while it ran")
    func sameSignInLeavesTheCategoriesMarkedSince() {
        let left = AppState.categoriesLeftToCheck(
            pending: ["assignments", "courses"], checked: ["assignments"], signedOutSince: false
        )

        #expect(left == ["courses"])
    }

    @Test("A check the sign-out outlived leaves the next account's categories, though it compared the same ones")
    func signOutLeavesTheNextAccountsCategories() {
        let left = AppState.categoriesLeftToCheck(
            pending: ["assignments"], checked: ["assignments"], signedOutSince: true
        )

        #expect(left == ["assignments"])
    }

    @Test("A check the sign-out outlived checks nothing of the departing account's, so it raises no alert")
    func signOutLeavesNothingOfTheDepartingAccountToCheck() async {
        await withExclusiveRealDefaults {
            let saved = (Defaults[.pendingConflictCategories], Defaults[.assignmentMarksSyncedOnce])
            defer {
                Defaults[.pendingConflictCategories] = saved.0
                Defaults[.assignmentMarksSyncedOnce] = saved.1
            }
            // The check compares assignments, and courses is switched back on before the sign-out.
            Defaults[.pendingConflictCategories] = ["assignments", "courses"]

            AppState.forgetSyncProgress()

            let left = AppState.categoriesLeftToCheck(
                pending: Defaults[.pendingConflictCategories], checked: ["assignments"], signedOutSince: true
            )
            #expect(left.isEmpty)
        }
    }
}
