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
        #expect(AppState.fullSyncMayWrite(startedIn: 4, current: 4, cloudSyncEnabled: true, protectedDataAvailable: true))
    }

    @Test("A sign-out while the sync was in flight stops its writes, even after the next sign-in")
    func signOutDuringTheSyncStopsItsWrites() {
        #expect(!AppState.fullSyncMayWrite(startedIn: 4, current: 5, cloudSyncEnabled: true, protectedDataAvailable: true))
    }

    @Test("Turning Sync course information off while the sync was in flight stops its writes")
    func syncSwitchedOffDuringTheSyncStopsItsWrites() {
        #expect(!AppState.fullSyncMayWrite(startedIn: 4, current: 4, cloudSyncEnabled: false, protectedDataAvailable: true))
    }

    /// The phone locked while the request was out, and the reply woke the app behind the lock screen.
    @Test("A sync that resumes behind the lock screen writes nothing over the caches it cannot read")
    func syncResumedBehindTheLockScreenStopsItsWrites() {
        #expect(!AppState.fullSyncMayWrite(startedIn: 4, current: 4, cloudSyncEnabled: true, protectedDataAvailable: false))
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
                Defaults[.lastSeenCoursesResetAt], Defaults[.categoriesSyncedOnce], Defaults[.courseRowIdsSeen]
            )
            defer {
                Defaults[.pendingConflictCategories] = saved.0
                Defaults[.assignmentMarksSyncedOnce] = saved.1
                Defaults[.lastSeenCoursesResetAt] = saved.2
                Defaults[.categoriesSyncedOnce] = saved.3
                Defaults[.courseRowIdsSeen] = saved.4
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

/// `AppState.ConflictCheckRetry`: when a full sync or a revision poll that reached the server runs
/// the pending re-enable check again. The outbox holds a course setting while the Assignments check
/// is pending, and the check used to run only from the Settings screens, so one that failed offline
/// kept the setting from the server until the next visit there.
struct ConflictCheckRetryTests {
    private static let start = Date(timeIntervalSince1970: 1_790_000_000)

    private static func isDue(
        _ retry: AppState.ConflictCheckRetry, after seconds: TimeInterval = 0,
        pending: Set<String> = ["assignments"], checking: Bool = false, awaitingAnswer: Bool = false,
        generation: Int = 0
    ) -> Bool {
        retry.isDue(
            pending: pending, checking: checking, awaitingAnswer: awaitingAnswer,
            now: start.addingTimeInterval(seconds), generation: generation
        )
    }

    @Test("A check is owed from launch, but none starts with nothing pending, one running or a dialog up")
    func owedFromLaunch() {
        let retry = AppState.ConflictCheckRetry()

        #expect(Self.isDue(retry))
        #expect(!Self.isDue(retry, pending: []))
        #expect(!Self.isDue(retry, checking: true))
        #expect(!Self.isDue(retry, awaitingAnswer: true))
    }

    /// A weak link can answer the small revision poll every ten seconds while the snapshot keeps
    /// timing out, and each `/sync/full` costs the server a log row and pushes its own sync back.
    @Test("A failed check runs again only after a wait that doubles with each failure, up to half an hour")
    func failuresBackOff() {
        var retry = AppState.ConflictCheckRetry()

        retry.noteFailure(at: Self.start, generation: 0)
        #expect(!Self.isDue(retry, after: AppState.ConflictCheckRetry.firstDelay - 1))
        #expect(Self.isDue(retry, after: AppState.ConflictCheckRetry.firstDelay))

        retry.noteFailure(at: Self.start, generation: 0)
        #expect(!Self.isDue(retry, after: 2 * AppState.ConflictCheckRetry.firstDelay - 1))
        #expect(Self.isDue(retry, after: 2 * AppState.ConflictCheckRetry.firstDelay))

        for _ in 0..<20 { retry.noteFailure(at: Self.start, generation: 0) }
        #expect(!Self.isDue(retry, after: AppState.ConflictCheckRetry.maxDelay - 1))
        #expect(Self.isDue(retry, after: AppState.ConflictCheckRetry.maxDelay))
    }

    @Test("A verdict settles the check, a dropped result is owed again after the wait, and one answered meanwhile changes nothing")
    func outcomesMoveWhatIsOwed() {
        var retry = AppState.ConflictCheckRetry()

        retry.note(.clear(["assignments"]), at: Self.start, generation: 0)
        #expect(!Self.isDue(retry, after: 3600))
        retry.note(.resolvedMeanwhile, at: Self.start, generation: 0)
        #expect(!Self.isDue(retry, after: 3600))

        retry.note(.dropped, at: Self.start, generation: 0)
        #expect(!Self.isDue(retry, after: 1))
        #expect(Self.isDue(retry, after: AppState.ConflictCheckRetry.firstDelay))

        retry.note(.conflict(["assignments"]), at: Self.start, generation: 0)
        #expect(!Self.isDue(retry, after: 3600))
        // The wait starts over after a verdict.
        retry.noteFailure(at: Self.start, generation: 0)
        #expect(Self.isDue(retry, after: AppState.ConflictCheckRetry.firstDelay))
    }

    /// The one-at-a-time guard turns away the check of a category switched back on while another
    /// runs. When the running check asked, nothing checked the later category after the answer,
    /// and its course settings and marks waited in the outbox.
    @Test("Once the dialog is answered, a category switched back on while its check ran is checked")
    func anAnswerOwesTheCategoriesMarkedDuringTheCheck() {
        var retry = AppState.ConflictCheckRetry()

        // The courses check finds a difference; Assignments was switched back on while it ran.
        retry.note(.conflict(["courses"]), at: Self.start, generation: 0)
        #expect(!Self.isDue(retry, pending: ["assignments", "courses"], awaitingAnswer: true))

        retry.noteAnswered(leaving: ["assignments"], generation: 0)
        #expect(Self.isDue(retry, pending: ["assignments"]))
    }

    @Test("An answer that leaves nothing pending owes no check")
    func anAnswerThatLeavesNothingOwesNothing() {
        var retry = AppState.ConflictCheckRetry()
        retry.note(.conflict(["courses"]), at: Self.start, generation: 0)

        retry.noteAnswered(leaving: [], generation: 0)

        // A category switched back on later is checked by the Settings screen that marks it.
        #expect(!Self.isDue(retry, pending: ["assignments"]))
    }

    /// A sign-out moves the login generation. The departing account's failures used to stay, so
    /// after five of them the next account's first failed check waited 16 minutes, not 30 seconds.
    @Test("The next account starts as at launch, even after the departing account's check ends late")
    func aSignOutStartsTheRetriesOver() {
        var retry = AppState.ConflictCheckRetry()
        for _ in 0..<5 { retry.noteFailure(at: Self.start, generation: 4) }
        // The departing account's check ends after the sign-out.
        retry.note(.dropped, at: Self.start, generation: 4)
        #expect(!Self.isDue(retry, generation: 4))

        #expect(Self.isDue(retry, generation: 5))
        retry.noteFailure(at: Self.start, generation: 5)
        #expect(!Self.isDue(retry, after: AppState.ConflictCheckRetry.firstDelay - 1, generation: 5))
        #expect(Self.isDue(retry, after: AppState.ConflictCheckRetry.firstDelay, generation: 5))
    }
}

/// `AppState.conflictCheckOutcome`: what a finished re-enable check does with its result.
struct ConflictCheckOutcomeTests {
    @Test("A sign-out, sync turned off or the lock screen since the check started drops its result")
    func overtakenResultsAreDropped() {
        #expect(AppState.conflictCheckOutcome(
            mayWrite: false, checked: ["assignments"], stillPending: ["assignments"], foundDifference: true
        ) == .dropped)
    }

    @Test("A check whose categories were all answered while it ran reports nothing")
    func answeredMeanwhileReportsNothing() {
        #expect(AppState.conflictCheckOutcome(
            mayWrite: true, checked: ["assignments"], stillPending: ["courses"], foundDifference: true
        ) == .resolvedMeanwhile)
    }

    @Test("A difference asks about the categories still pending, and none clears them, which drains the outbox")
    func verdictsCoverTheCategoriesStillPending() {
        #expect(AppState.conflictCheckOutcome(
            mayWrite: true, checked: ["assignments", "courses"], stillPending: ["assignments"], foundDifference: true
        ) == .conflict(["assignments"]))
        #expect(AppState.conflictCheckOutcome(
            mayWrite: true, checked: ["assignments"], stillPending: ["assignments", "courses"], foundDifference: false
        ) == .clear(["assignments"]))
    }
}

/// `AppState.markForReenableCheck`: which categories switched back on wait for the re-enable check.
/// A device that has not taken a category's data holds no copy of it, so the check has nothing to
/// compare there, and Use Local would send this device's own over the server's.
@MainActor
struct ReenableMarkTests {
    private static let categories: Set<String> = ["courses", "course_colors", "course_names", "assignments"]
    private static let switches: [(category: String, key: Defaults.Key<Bool>)] = [
        ("courses", .syncCourses), ("course_colors", .syncCourseColors),
        ("course_names", .syncCourseNames), ("assignments", .syncAssignments),
    ]

    private static var synced: Set<String> { categories.filter { AppState.hasSynced($0) } }

    /// The sync progress keys and the sync switches are the app's real `Defaults`, which other
    /// suites read and write too, so these tests take the gate
    /// (docs/decisions/0020-real-defaults-gate.md). Each starts with every switch on and nothing taken.
    private static func withSyncProgress(_ body: () -> Void) async {
        await withExclusiveRealDefaults {
            let saved = (
                Defaults[.pendingConflictCategories], Defaults[.assignmentMarksSyncedOnce],
                Defaults[.lastSeenCoursesResetAt], Defaults[.categoriesSyncedOnce], Defaults[.courseRowIdsSeen]
            )
            let savedSwitches = switches.map { ($0.key, Defaults[$0.key]) }
            defer {
                Defaults[.pendingConflictCategories] = saved.0
                Defaults[.assignmentMarksSyncedOnce] = saved.1
                Defaults[.lastSeenCoursesResetAt] = saved.2
                Defaults[.categoriesSyncedOnce] = saved.3
                Defaults[.courseRowIdsSeen] = saved.4
                for (key, value) in savedSwitches { Defaults[key] = value }
            }
            Defaults[.pendingConflictCategories] = []
            Defaults[.categoriesSyncedOnce] = []
            for entry in switches { Defaults[entry.key] = true }
            body()
        }
    }

    /// Records a full sync as `runFullSync` does, with the switches `Defaults` holds.
    private static func recordSync(
        pendingChecks: Set<String> = [], marksLeftFor reason: AppState.MarksLeftReason? = nil
    ) {
        AppState.recordFullSync(coursesReset: .distantPast, taken: AppState.categoriesTaken(
            switchedOn: AppState.switchedOnCategories(), pendingChecks: pendingChecks, marksLeftFor: reason
        ))
    }

    @Test("A full sync takes a category's data unless a pending check or an edit during the fetch holds it back")
    func takenCategoriesFollowTheSyncsSkips() {
        let taken = { (pending: Set<String>, reason: AppState.MarksLeftReason?) in
            AppState.categoriesTaken(switchedOn: Self.categories, pendingChecks: pending, marksLeftFor: reason)
        }
        #expect(taken([], nil) == Self.categories)
        // One step applies colours and names, so a check pending on either holds back both.
        #expect(taken(["course_names"], nil) == ["courses", "assignments"])
        #expect(taken(["course_colors"], nil) == ["courses", "assignments"])
        #expect(taken(["courses"], nil) == ["course_colors", "course_names", "assignments"])
        #expect(taken([], .editedDuringFetch) == Self.categories.subtracting(["assignments"]))
        #expect(taken(["assignments"], .conflictCheckPending) == Self.categories.subtracting(["assignments"]))
        #expect(taken([], .switchedOff) == Self.categories.subtracting(["assignments"]))
        // Uploaded to a server that had none, the marks there are this device's.
        #expect(taken([], .uploadedLocalMarks) == Self.categories)
        #expect(AppState.categoriesTaken(switchedOn: ["courses"], pendingChecks: [], marksLeftFor: nil) == ["courses"])
    }

    @Test("Names a sync left for a pending colours check stay unrecorded, so switching them off and on checks nothing")
    func namesHeldForAColoursCheckAreNotRecorded() async {
        await Self.withSyncProgress {
            // Names off since the sign-in, so every sync since took the other three.
            Defaults[.categoriesSyncedOnce] = Self.categories.subtracting(["course_names"])
            Defaults[.pendingConflictCategories] = ["course_colors"]

            Self.recordSync(pendingChecks: Defaults[.pendingConflictCategories])
            AppState.markForReenableCheck("course_names", signedIn: true)

            #expect(!AppState.hasSynced("course_names"))
            #expect(Defaults[.pendingConflictCategories] == ["course_colors"])
        }
    }

    @Test("Marks a sync left for an edit made during its fetch stay unrecorded")
    func marksLeftForAnEditAreNotRecorded() async {
        await Self.withSyncProgress {
            Self.recordSync(marksLeftFor: .editedDuringFetch)

            #expect(Self.synced == Self.categories.subtracting(["assignments"]))
        }
    }

    @Test("A full sync records the categories it took, and a sign-out forgets them")
    func aFullSyncRecordsItsCategoriesAndASignOutForgetsThem() async {
        await Self.withSyncProgress {
            Self.recordSync()
            Defaults[.courseRowIdsSeen] = ["1151:CS1": 1]

            #expect(Self.synced == Self.categories)
            #expect(Defaults[.lastSeenCoursesResetAt] == Date.distantPast)

            AppState.forgetSyncProgress()

            #expect(Self.synced.isEmpty)
            #expect(Defaults[.courseRowIdsSeen].isEmpty)
        }
    }

    @Test("A full sync with a category's switch off takes none of its data, so switching it back on checks nothing for it",
          arguments: ["courses", "course_colors", "course_names", "assignments"])
    func aSyncWithASwitchOffLeavesItsCategoryUnchecked(category: String) async {
        await Self.withSyncProgress {
            for entry in Self.switches where entry.category == category { Defaults[entry.key] = false }
            // As the sync passes it, which takes the marks only with their switch on.
            Self.recordSync(marksLeftFor: AppState.reasonToLeaveMarks(
                syncsMarks: Defaults[.syncAssignments], conflictCheckPending: false,
                uploadedLocalMarks: false, editedDuringFetch: false
            ))

            for name in Self.categories { AppState.markForReenableCheck(name, signedIn: true) }

            #expect(Defaults[.pendingConflictCategories] == Self.categories.subtracting([category]))
        }
    }

    @Test("A full sync that read the Assignments switch off before its fetch takes no marks, though the switch is on by its end")
    func aSyncThatLeftTheMarksLeavesThemUnchecked() async {
        await Self.withSyncProgress {
            Self.recordSync(marksLeftFor: .switchedOff)

            #expect(Self.synced == Self.categories.subtracting(["assignments"]))
        }
    }

    @Test("After a sign-out and a sign-in, turning TigerSync on raises no check, and the first pull takes the server's marks")
    func turningSyncOnAfterASignInChecksNothing() async {
        await Self.withSyncProgress {
            // As a full sync of the departing account leaves them, its server holding no reset.
            Defaults[.assignmentMarksSyncedOnce] = true
            Self.recordSync()

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

    @Test("Turning TigerSync back on after a sync with every switch on checks every category, whatever assignmentMarksSyncedOnce says",
          arguments: [true, false])
    func turningSyncBackOnAfterASyncChecksEveryCategory(marksSynced: Bool) async {
        await Self.withSyncProgress {
            // The update records the categories of an account signed in then and leaves this flag false.
            Defaults[.assignmentMarksSyncedOnce] = marksSynced
            Self.recordSync()

            for category in Self.categories { AppState.markForReenableCheck(category, signedIn: true) }

            #expect(Defaults[.pendingConflictCategories] == Self.categories)
        }
    }

    @Test("Switching a category back on while signed out marks nothing for whoever signs in next")
    func signedOutMarksNothing() async {
        await Self.withSyncProgress {
            // Recorded as after a sync, so the sign-in alone decides.
            Defaults[.assignmentMarksSyncedOnce] = true
            Self.recordSync()

            for category in Self.categories { AppState.markForReenableCheck(category, signedIn: false) }

            #expect(Defaults[.pendingConflictCategories].isEmpty)
        }
    }
}
