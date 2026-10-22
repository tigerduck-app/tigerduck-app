import Defaults
import Foundation
import Testing
@testable import TigerDuck

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

    @Test("A sync that resumes behind the lock screen writes nothing over the caches it cannot read")
    func syncResumedBehindTheLockScreenStopsItsWrites() {
        #expect(!AppState.fullSyncMayWrite(startedIn: 4, current: 4, cloudSyncEnabled: true, protectedDataAvailable: false))
    }
}

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
            Defaults[.pendingConflictCategories] = ["assignments", "courses"]

            AppState.forgetSyncProgress()

            let left = AppState.categoriesLeftToCheck(
                pending: Defaults[.pendingConflictCategories], checked: ["assignments"], signedOutSince: true
            )
            #expect(left.isEmpty)
        }
    }
}

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
        retry.noteFailure(at: Self.start, generation: 0)
        #expect(Self.isDue(retry, after: AppState.ConflictCheckRetry.firstDelay))
    }

    @Test("Once the dialog is answered, a category switched back on while its check ran is checked")
    func anAnswerOwesTheCategoriesMarkedDuringTheCheck() {
        var retry = AppState.ConflictCheckRetry()

        retry.note(.conflict(["courses"]), at: Self.start, generation: 0)
        #expect(!Self.isDue(retry, pending: ["assignments", "courses"], awaitingAnswer: true))

        retry.noteAnswered(leaving: ["assignments"], awaitingAnswer: false, generation: 0)
        #expect(Self.isDue(retry, pending: ["assignments"]))
    }

    @Test("An answer that leaves nothing pending owes no check")
    func anAnswerThatLeavesNothingOwesNothing() {
        var retry = AppState.ConflictCheckRetry()
        retry.note(.conflict(["courses"]), at: Self.start, generation: 0)

        retry.noteAnswered(leaving: [], awaitingAnswer: false, generation: 0)

        #expect(!Self.isDue(retry, pending: ["assignments"]))
    }

    @Test("An answer that finds another dialog up owes no check of its own")
    func anAnswerWithAnotherDialogUpOwesNothing() {
        var retry = AppState.ConflictCheckRetry()
        retry.note(.conflict(["courses"]), at: Self.start, generation: 0)
        retry.note(.conflict(["assignments"]), at: Self.start, generation: 0)

        retry.noteAnswered(leaving: ["assignments"], awaitingAnswer: true, generation: 0)

        #expect(!Self.isDue(retry, pending: ["assignments"]))
    }

    @Test("A check of the departing account that ends after the next account's verdict changes nothing")
    func anOlderAccountsLateResultIsDropped() {
        var retry = AppState.ConflictCheckRetry()
        retry.note(.clear(["assignments"]), at: Self.start, generation: 5)
        #expect(!Self.isDue(retry, generation: 5))

        retry.note(.dropped, at: Self.start, generation: 4)
        retry.noteFailure(at: Self.start, generation: 4)
        retry.noteAnswered(leaving: ["assignments"], awaitingAnswer: false, at: Self.start, generation: 4)

        #expect(!Self.isDue(retry, generation: 5))
    }

    @Test("An answer whose save failed is checked again only after the wait a failed check gets")
    func aFailedSaveWaitsBeforeAskingAgain() {
        var retry = AppState.ConflictCheckRetry()
        retry.note(.conflict(["courses"]), at: Self.start, generation: 0)

        retry.noteAnswered(leaving: ["courses"], awaitingAnswer: false, saveFailed: true, at: Self.start, generation: 0)

        #expect(!Self.isDue(retry, pending: ["courses"]))
        #expect(Self.isDue(retry, after: AppState.ConflictCheckRetry.firstDelay, pending: ["courses"]))
    }

    @Test("The next account starts as at launch, even after the departing account's check ends late")
    func aSignOutStartsTheRetriesOver() {
        var retry = AppState.ConflictCheckRetry()
        for _ in 0..<5 { retry.noteFailure(at: Self.start, generation: 4) }
        retry.note(.dropped, at: Self.start, generation: 4)
        #expect(!Self.isDue(retry, generation: 4))

        #expect(Self.isDue(retry, generation: 5))
        retry.noteFailure(at: Self.start, generation: 5)
        #expect(!Self.isDue(retry, after: AppState.ConflictCheckRetry.firstDelay - 1, generation: 5))
        #expect(Self.isDue(retry, after: AppState.ConflictCheckRetry.firstDelay, generation: 5))
    }
}

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

    @Test("A check that compared what a Use Local answer still sends asks nothing about it")
    func whatUseLocalStillSendsIsNotAskedAgain() {
        let stillPending = AppState.categoriesToCheck(
            pending: ["course_colors", "courses"], answering: ["course_colors"]
        )

        #expect(AppState.conflictCheckOutcome(
            mayWrite: true, checked: ["course_colors"], stillPending: stillPending, foundDifference: true
        ) == .resolvedMeanwhile)
        #expect(AppState.conflictCheckOutcome(
            mayWrite: true, checked: ["course_colors", "courses"], stillPending: stillPending, foundDifference: true
        ) == .conflict(["courses"]))
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

@MainActor
struct ReenableMarkTests {
    private static let categories: Set<String> = ["courses", "course_colors", "course_names", "assignments"]
    private static let switches: [(category: String, key: Defaults.Key<Bool>)] = [
        ("courses", .syncCourses), ("course_colors", .syncCourseColors),
        ("course_names", .syncCourseNames), ("assignments", .syncAssignments),
    ]

    private static var synced: Set<String> { categories.filter { AppState.hasSynced($0) } }

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
        #expect(taken(["course_names"], nil) == ["courses", "assignments"])
        #expect(taken(["course_colors"], nil) == ["courses", "assignments"])
        #expect(taken(["courses"], nil) == ["course_colors", "course_names", "assignments"])
        #expect(taken([], .editedDuringFetch) == Self.categories.subtracting(["assignments"]))
        #expect(taken(["assignments"], .conflictCheckPending) == Self.categories.subtracting(["assignments"]))
        #expect(taken([], .switchedOff) == Self.categories.subtracting(["assignments"]))
        #expect(taken([], .uploadedLocalMarks) == Self.categories)
        #expect(AppState.categoriesTaken(switchedOn: ["courses"], pendingChecks: [], marksLeftFor: nil) == ["courses"])
    }

    @Test("Use Local keeps every category it answers pending until it is done with it, and only a relaunch asks again")
    func useLocalKeepsWhatItAnswersPending() {
        var pending = Self.categories
        var hold = AppState.UseLocalHold()

        let held = hold.take(Array(Self.categories), keepLocal: true, from: &pending)

        #expect(pending == Self.categories)
        #expect(held == pending)
        #expect(AppState.categoriesTaken(
            switchedOn: Self.categories,
            pendingChecks: pending,
            marksLeftFor: AppState.reasonToLeaveMarks(
                syncsMarks: true, conflictCheckPending: pending.contains("assignments"),
                uploadedLocalMarks: false, editedDuringFetch: false
            )
        ).isEmpty)
        #expect(AppState.categoriesToCheck(pending: pending, answering: hold.held).isEmpty)
        #expect(AppState.categoriesToCheck(pending: pending, answering: AppState.UseLocalHold().held) == pending)

        hold.release(held, from: &pending)

        #expect(pending.isEmpty)
        #expect(hold == AppState.UseLocalHold())
    }

    @Test("Use Server takes every answered category off the pending list at once and holds none")
    func useServerHoldsNothing() {
        var pending: Set<String> = ["courses", "course_colors", "assignments"]
        var hold = AppState.UseLocalHold()

        let held = hold.take(["course_colors", "assignments"], keepLocal: false, from: &pending)

        #expect(held.isEmpty)
        #expect(pending == ["courses"])
        #expect(hold.held.isEmpty)
    }

    @Test("A category switched off and on while Use Local sends it stays pending for its own check")
    func aReenableWhileUseLocalSendsItStaysPending() {
        var pending: Set<String> = ["courses", "course_colors", "course_names"]
        var hold = AppState.UseLocalHold()
        let held = hold.take(["courses", "course_colors", "course_names"], keepLocal: true, from: &pending)

        pending.insert("course_colors")
        hold.noteReenabled("course_colors")
        hold.noteReenabled("assignments")
        hold.release(held, from: &pending)

        #expect(pending == ["course_colors"])
        #expect(hold == AppState.UseLocalHold())
    }

    @Test("Two Use Local answers each let go of only what they held")
    func eachAnswerReleasesOnlyItsOwn() {
        var pending: Set<String> = ["courses", "course_colors", "course_names", "assignments"]
        var hold = AppState.UseLocalHold()
        let first = hold.take(["courses", "course_colors"], keepLocal: true, from: &pending)
        let second = hold.take(["assignments"], keepLocal: true, from: &pending)

        hold.release(second, from: &pending)

        #expect(pending == ["courses", "course_colors", "course_names"])
        #expect(hold.held == first)
    }

    @Test("Names a sync left for a pending colours check stay unrecorded, so switching them off and on checks nothing")
    func namesHeldForAColoursCheckAreNotRecorded() async {
        await Self.withSyncProgress {
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
            Defaults[.assignmentMarksSyncedOnce] = marksSynced
            Self.recordSync()

            for category in Self.categories { AppState.markForReenableCheck(category, signedIn: true) }

            #expect(Defaults[.pendingConflictCategories] == Self.categories)
        }
    }

    @Test("Switching a category back on while signed out marks nothing for whoever signs in next")
    func signedOutMarksNothing() async {
        await Self.withSyncProgress {
            Defaults[.assignmentMarksSyncedOnce] = true
            Self.recordSync()

            for category in Self.categories { AppState.markForReenableCheck(category, signedIn: false) }

            #expect(Defaults[.pendingConflictCategories].isEmpty)
        }
    }
}
