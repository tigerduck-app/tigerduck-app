import Defaults
import Foundation
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
            let saved = (
                Defaults[.pendingConflictCategories], Defaults[.assignmentMarksSyncedOnce],
                Defaults[.lastSeenCoursesResetAt], Defaults[.accountSyncedOnce]
            )
            defer {
                Defaults[.pendingConflictCategories] = saved.0
                Defaults[.assignmentMarksSyncedOnce] = saved.1
                Defaults[.lastSeenCoursesResetAt] = saved.2
                Defaults[.accountSyncedOnce] = saved.3
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

/// `AppState.markForReenableCheck`: which categories switched back on wait for the re-enable check.
/// A device that has not synced the account holds none of its data, so the check has nothing to
/// compare there, and Use Local would send the empty caches over the server's.
@MainActor
struct ReenableMarkTests {
    private static let categories: Set<String> = ["courses", "course_colors", "course_names", "assignments"]

    /// The sync progress keys are the app's real `Defaults`, which other suites read and write
    /// too, so these tests take the gate (docs/decisions/0020-real-defaults-gate.md).
    private static func withSyncProgress(_ body: () -> Void) async {
        await withExclusiveRealDefaults {
            let saved = (
                Defaults[.pendingConflictCategories], Defaults[.assignmentMarksSyncedOnce],
                Defaults[.lastSeenCoursesResetAt], Defaults[.accountSyncedOnce]
            )
            defer {
                Defaults[.pendingConflictCategories] = saved.0
                Defaults[.assignmentMarksSyncedOnce] = saved.1
                Defaults[.lastSeenCoursesResetAt] = saved.2
                Defaults[.accountSyncedOnce] = saved.3
            }
            Defaults[.pendingConflictCategories] = []
            Defaults[.accountSyncedOnce] = false
            body()
        }
    }

    @Test("A full sync records that this device holds the account's data, and a sign-out forgets it")
    func aFullSyncRecordsTheAccountAndASignOutForgetsIt() async {
        await Self.withSyncProgress {
            AppState.recordFullSync(coursesReset: .distantPast)

            #expect(AppState.hasSyncedAccount)
            #expect(Defaults[.lastSeenCoursesResetAt] == .distantPast)

            AppState.forgetSyncProgress()

            #expect(!AppState.hasSyncedAccount)
        }
    }

    @Test("After a sign-out and a sign-in, turning TigerSync on raises no check, and the first pull takes the server's marks")
    func turningSyncOnAfterASignInChecksNothing() async {
        await Self.withSyncProgress {
            // As a full sync of the departing account leaves them, its server holding no reset.
            Defaults[.assignmentMarksSyncedOnce] = true
            AppState.recordFullSync(coursesReset: .distantPast)

            AppState.forgetSyncProgress()
            for category in Self.categories { AppState.markForReenableCheck(category, signedIn: true) }

            #expect(Defaults[.pendingConflictCategories].isEmpty)
            #expect(AppState.reasonToLeaveMarks(
                syncsMarks: true,
                conflictCheckPending: Defaults[.pendingConflictCategories].contains("assignments"),
                uploadedLocalMarks: false,
                editedDuringFetch: false
            ) == nil)
        }
    }

    @Test("Turning TigerSync back on after a sync checks every category, whether or not that sync took marks",
          arguments: [true, false])
    func turningSyncBackOnAfterASyncChecksEveryCategory(marksSynced: Bool) async {
        await Self.withSyncProgress {
            // Every full sync records itself; only one with the Assignments switch on sets the flag.
            Defaults[.assignmentMarksSyncedOnce] = marksSynced
            AppState.recordFullSync(coursesReset: .distantPast)

            for category in Self.categories { AppState.markForReenableCheck(category, signedIn: true) }

            #expect(Defaults[.pendingConflictCategories] == Self.categories)
        }
    }

    @Test("Switching a category back on while signed out marks nothing for whoever signs in next")
    func signedOutMarksNothing() async {
        await Self.withSyncProgress {
            // Recorded as after a sync, so the sign-in alone decides.
            Defaults[.assignmentMarksSyncedOnce] = true
            AppState.recordFullSync(coursesReset: .distantPast)

            for category in Self.categories { AppState.markForReenableCheck(category, signedIn: false) }

            #expect(Defaults[.pendingConflictCategories].isEmpty)
        }
    }
}
