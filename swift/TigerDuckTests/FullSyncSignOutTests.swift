import Defaults
import Foundation
import Testing
@testable import TigerDuck

struct FullSyncSignOutTests {
    @Test("A sync the sign-in and the sync switch both outlived may write")
    func syncThatOutlivedNothingMayWrite() {
        #expect(FullSyncRunner.fullSyncMayWrite(signedOutSince: false, cloudSyncEnabled: true, protectedDataAvailable: true))
    }

    @Test("A sign-out while the sync was in flight stops its writes, even after the next sign-in")
    func signOutDuringTheSyncStopsItsWrites() {
        #expect(!FullSyncRunner.fullSyncMayWrite(signedOutSince: true, cloudSyncEnabled: true, protectedDataAvailable: true))
    }

    @Test("Turning Sync course information off while the sync was in flight stops its writes")
    func syncSwitchedOffDuringTheSyncStopsItsWrites() {
        #expect(!FullSyncRunner.fullSyncMayWrite(signedOutSince: false, cloudSyncEnabled: false, protectedDataAvailable: true))
    }

    @Test("A sync that resumes behind the lock screen writes nothing over the caches it cannot read")
    func syncResumedBehindTheLockScreenStopsItsWrites() {
        #expect(!FullSyncRunner.fullSyncMayWrite(signedOutSince: false, cloudSyncEnabled: true, protectedDataAvailable: false))
    }
}

@MainActor
struct ReenableCheckSignOutTests {
    @Test("A check that ends under the same sign-in leaves the categories switched back on while it ran")
    func sameSignInLeavesTheCategoriesMarkedSince() {
        let left = SyncConflicts.categoriesLeftToCheck(
            pending: [.assignments, .courses], checked: [.assignments], signedOutSince: false
        )

        #expect(left == [.courses])
    }

    @Test("A check the sign-out outlived leaves the next account's categories, though it compared the same ones")
    func signOutLeavesTheNextAccountsCategories() {
        let left = SyncConflicts.categoriesLeftToCheck(
            pending: [.assignments], checked: [.assignments], signedOutSince: true
        )

        #expect(left == [.assignments])
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
            Defaults[.pendingConflictCategories] = [.assignments, .courses]

            SyncProgress.forget()

            let left = SyncConflicts.categoriesLeftToCheck(
                pending: Defaults[.pendingConflictCategories], checked: [.assignments], signedOutSince: true
            )
            #expect(left.isEmpty)
        }
    }
}

@MainActor
struct ConflictCheckRetryTests {
    private static let start = Date(timeIntervalSince1970: 1_790_000_000)
    private static let (departing, next): (SignIn, SignIn) = {
        let session = AccountSession()
        let departing = session.signIns.currentSignIn
        return (departing, session.endSignIn())
    }()

    private static func isDue(
        _ retry: SyncConflicts.ConflictCheckRetry, after seconds: TimeInterval = 0,
        pending: Set<SyncCategory> = [.assignments], checking: Bool = false, awaitingAnswer: Bool = false
    ) -> Bool {
        retry.isDue(
            pending: pending, checking: checking, awaitingAnswer: awaitingAnswer,
            now: start.addingTimeInterval(seconds)
        )
    }

    @Test("A check is owed from launch, but none starts with nothing pending, one running or a dialog up")
    func owedFromLaunch() {
        let retry = SyncConflicts.ConflictCheckRetry()

        #expect(Self.isDue(retry))
        #expect(!Self.isDue(retry, pending: []))
        #expect(!Self.isDue(retry, checking: true))
        #expect(!Self.isDue(retry, awaitingAnswer: true))
    }

    @Test("A failed check runs again only after a wait that doubles with each failure, up to half an hour")
    func failuresBackOff() {
        var retry = SyncConflicts.ConflictCheckRetry()

        retry.noteFailure(at: Self.start, signIn: testSignIn)
        #expect(!Self.isDue(retry, after: SyncConflicts.ConflictCheckRetry.firstDelay - 1))
        #expect(Self.isDue(retry, after: SyncConflicts.ConflictCheckRetry.firstDelay))

        retry.noteFailure(at: Self.start, signIn: testSignIn)
        #expect(!Self.isDue(retry, after: 2 * SyncConflicts.ConflictCheckRetry.firstDelay - 1))
        #expect(Self.isDue(retry, after: 2 * SyncConflicts.ConflictCheckRetry.firstDelay))

        for _ in 0..<20 { retry.noteFailure(at: Self.start, signIn: testSignIn) }
        #expect(!Self.isDue(retry, after: SyncConflicts.ConflictCheckRetry.maxDelay - 1))
        #expect(Self.isDue(retry, after: SyncConflicts.ConflictCheckRetry.maxDelay))
    }

    @Test("A verdict settles the check, a dropped result is owed again after the wait, and one answered meanwhile changes nothing")
    func outcomesMoveWhatIsOwed() {
        var retry = SyncConflicts.ConflictCheckRetry()

        retry.note(.clear([.assignments]), at: Self.start, signIn: testSignIn)
        #expect(!Self.isDue(retry, after: 3600))
        retry.note(.resolvedMeanwhile, at: Self.start, signIn: testSignIn)
        #expect(!Self.isDue(retry, after: 3600))

        retry.note(.dropped, at: Self.start, signIn: testSignIn)
        #expect(!Self.isDue(retry, after: 1))
        #expect(Self.isDue(retry, after: SyncConflicts.ConflictCheckRetry.firstDelay))

        retry.note(.conflict([.assignments]), at: Self.start, signIn: testSignIn)
        #expect(!Self.isDue(retry, after: 3600))
        retry.noteFailure(at: Self.start, signIn: testSignIn)
        #expect(Self.isDue(retry, after: SyncConflicts.ConflictCheckRetry.firstDelay))
    }

    @Test("Once the dialog is answered, a category switched back on while its check ran is checked")
    func anAnswerOwesTheCategoriesMarkedDuringTheCheck() {
        var retry = SyncConflicts.ConflictCheckRetry()

        retry.note(.conflict([.courses]), at: Self.start, signIn: testSignIn)
        #expect(!Self.isDue(retry, pending: [.assignments, .courses], awaitingAnswer: true))

        retry.noteAnswered(leaving: [.assignments], awaitingAnswer: false, signIn: testSignIn)
        #expect(Self.isDue(retry, pending: [.assignments]))
    }

    @Test("An answer that leaves nothing pending owes no check")
    func anAnswerThatLeavesNothingOwesNothing() {
        var retry = SyncConflicts.ConflictCheckRetry()
        retry.note(.conflict([.courses]), at: Self.start, signIn: testSignIn)

        retry.noteAnswered(leaving: [], awaitingAnswer: false, signIn: testSignIn)

        #expect(!Self.isDue(retry, pending: [.assignments]))
    }

    @Test("An answer that finds another dialog up owes no check of its own")
    func anAnswerWithAnotherDialogUpOwesNothing() {
        var retry = SyncConflicts.ConflictCheckRetry()
        retry.note(.conflict([.courses]), at: Self.start, signIn: testSignIn)
        retry.note(.conflict([.assignments]), at: Self.start, signIn: testSignIn)

        retry.noteAnswered(leaving: [.assignments], awaitingAnswer: true, signIn: testSignIn)

        #expect(!Self.isDue(retry, pending: [.assignments]))
    }

    @Test("A check of the departing account that ends after the next account's verdict changes nothing")
    func anOlderAccountsLateResultIsDropped() {
        var retry = SyncConflicts.ConflictCheckRetry()
        retry.note(.clear([.assignments]), at: Self.start, signIn: Self.next)
        #expect(!Self.isDue(retry))

        retry.note(.dropped, at: Self.start, signIn: Self.departing)
        retry.noteFailure(at: Self.start, signIn: Self.departing)
        retry.noteAnswered(leaving: [.assignments], awaitingAnswer: false, at: Self.start, signIn: Self.departing)

        #expect(!Self.isDue(retry))
    }

    @Test("An answer whose save failed is checked again only after the wait a failed check gets")
    func aFailedSaveWaitsBeforeAskingAgain() {
        var retry = SyncConflicts.ConflictCheckRetry()
        retry.note(.conflict([.courses]), at: Self.start, signIn: testSignIn)

        retry.noteAnswered(leaving: [.courses], awaitingAnswer: false, saveFailed: true, at: Self.start, signIn: testSignIn)

        #expect(!Self.isDue(retry, pending: [.courses]))
        #expect(Self.isDue(retry, after: SyncConflicts.ConflictCheckRetry.firstDelay, pending: [.courses]))
    }

    @Test("The next account starts as at launch, even after the departing account's check ends late")
    func aSignOutStartsTheRetriesOver() {
        let session = AccountSession()
        let departing = session.signIns.currentSignIn
        var retry = SyncConflicts.ConflictCheckRetry()
        for _ in 0..<5 { retry.noteFailure(at: Self.start, signIn: departing) }
        #expect(!Self.isDue(retry))
        let next = session.endSignIn()
        retry.note(.dropped, at: Self.start, signIn: departing)

        #expect(Self.isDue(retry))
        retry.noteFailure(at: Self.start, signIn: next)
        #expect(!Self.isDue(retry, after: SyncConflicts.ConflictCheckRetry.firstDelay - 1))
        #expect(Self.isDue(retry, after: SyncConflicts.ConflictCheckRetry.firstDelay))
    }
}

struct ConflictCheckOutcomeTests {
    @Test("A sign-out, sync turned off or the lock screen since the check started drops its result")
    func overtakenResultsAreDropped() {
        #expect(SyncConflicts.conflictCheckOutcome(
            mayWrite: false, checked: [.assignments], stillPending: [.assignments], foundDifference: true
        ) == .dropped)
    }

    @Test("A check whose categories were all answered while it ran reports nothing")
    func answeredMeanwhileReportsNothing() {
        #expect(SyncConflicts.conflictCheckOutcome(
            mayWrite: true, checked: [.assignments], stillPending: [.courses], foundDifference: true
        ) == .resolvedMeanwhile)
    }

    @Test("A check that compared what a Use Local answer still sends asks nothing about it")
    func whatUseLocalStillSendsIsNotAskedAgain() {
        let stillPending = SyncConflicts.categoriesToCheck(
            pending: [.courseColors, .courses], answering: [.courseColors]
        )

        #expect(SyncConflicts.conflictCheckOutcome(
            mayWrite: true, checked: [.courseColors], stillPending: stillPending, foundDifference: true
        ) == .resolvedMeanwhile)
        #expect(SyncConflicts.conflictCheckOutcome(
            mayWrite: true, checked: [.courseColors, .courses], stillPending: stillPending, foundDifference: true
        ) == .conflict([.courses]))
    }

    @Test("A difference asks about the categories still pending, and none clears them, which drains the outbox")
    func verdictsCoverTheCategoriesStillPending() {
        #expect(SyncConflicts.conflictCheckOutcome(
            mayWrite: true, checked: [.assignments, .courses], stillPending: [.assignments], foundDifference: true
        ) == .conflict([.assignments]))
        #expect(SyncConflicts.conflictCheckOutcome(
            mayWrite: true, checked: [.assignments], stillPending: [.assignments, .courses], foundDifference: false
        ) == .clear([.assignments]))
    }
}

@MainActor
struct ReenableMarkTests {
    private static let categories = Set(SyncCategory.allCases)
    private static let switches: [(category: SyncCategory, key: Defaults.Key<Bool>)] = [
        (.courses, .syncCourses), (.courseColors, .syncCourseColors),
        (.courseNames, .syncCourseNames), (.assignments, .syncAssignments),
    ]

    private static var synced: Set<SyncCategory> { categories.filter { SyncConflicts.hasSynced($0) } }

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
        pendingChecks: Set<SyncCategory> = [], marksLeftFor reason: SyncPolicy.MarksLeftReason? = nil
    ) {
        SyncProgress.recordFullSync(coursesReset: .distantPast, taken: SyncPolicy(cloudSyncEnabled: true, switchedOn: SyncConflicts.switchedOnCategories(), pendingChecks: pendingChecks).categoriesTaken(marksLeftFor: reason), for: testSignIn)
    }

    @Test("A full sync takes a category's data unless a pending check or an edit during the fetch holds it back")
    func takenCategoriesFollowTheSyncsSkips() {
        let taken = { (pending: Set<SyncCategory>, reason: SyncPolicy.MarksLeftReason?) in
            SyncPolicy(cloudSyncEnabled: true, switchedOn: Self.categories, pendingChecks: pending).categoriesTaken(marksLeftFor: reason)
        }
        #expect(taken([], nil) == Self.categories)
        #expect(taken([.courseNames], nil) == [.courses, .assignments])
        #expect(taken([.courseColors], nil) == [.courses, .assignments])
        #expect(taken([.courses], nil) == [.courseColors, .courseNames, .assignments])
        #expect(taken([], .editedDuringFetch) == Self.categories.subtracting([.assignments]))
        #expect(taken([.assignments], .conflictCheckPending) == Self.categories.subtracting([.assignments]))
        #expect(taken([], .switchedOff) == Self.categories.subtracting([.assignments]))
        #expect(taken([], .uploadedLocalMarks) == Self.categories)
        #expect(SyncPolicy(cloudSyncEnabled: true, switchedOn: [.courses], pendingChecks: []).categoriesTaken(marksLeftFor: nil) == [.courses])
    }

    @Test("Use Local keeps every category it answers pending until it is done with it, and only a relaunch asks again")
    func useLocalKeepsWhatItAnswersPending() {
        var pending = Self.categories
        var hold = SyncConflicts.UseLocalHold()

        let held = hold.take(Array(Self.categories), keepLocal: true, from: &pending)

        #expect(pending == Self.categories)
        #expect(held == pending)
        #expect(SyncPolicy(cloudSyncEnabled: true, switchedOn: Self.categories, pendingChecks: pending).categoriesTaken(marksLeftFor: SyncPolicy.reasonToLeaveMarks(
                syncsMarks: true, conflictCheckPending: pending.contains(.assignments),
                uploadedLocalMarks: false, editedDuringFetch: false
            )).isEmpty)
        #expect(SyncConflicts.categoriesToCheck(pending: pending, answering: hold.held).isEmpty)
        #expect(SyncConflicts.categoriesToCheck(pending: pending, answering: SyncConflicts.UseLocalHold().held) == pending)

        hold.release(held, from: &pending)

        #expect(pending.isEmpty)
        #expect(hold == SyncConflicts.UseLocalHold())
    }

    @Test("Use Server takes every answered category off the pending list at once and holds none")
    func useServerHoldsNothing() {
        var pending: Set<SyncCategory> = [.courses, .courseColors, .assignments]
        var hold = SyncConflicts.UseLocalHold()

        let held = hold.take([.courseColors, .assignments], keepLocal: false, from: &pending)

        #expect(held.isEmpty)
        #expect(pending == [.courses])
        #expect(hold.held.isEmpty)
    }

    @Test("A category switched off and on while Use Local sends it stays pending for its own check")
    func aReenableWhileUseLocalSendsItStaysPending() {
        var pending: Set<SyncCategory> = [.courses, .courseColors, .courseNames]
        var hold = SyncConflicts.UseLocalHold()
        let held = hold.take([.courses, .courseColors, .courseNames], keepLocal: true, from: &pending)

        pending.insert(.courseColors)
        hold.noteReenabled(.courseColors)
        hold.noteReenabled(.assignments)
        hold.release(held, from: &pending)

        #expect(pending == [.courseColors])
        #expect(hold == SyncConflicts.UseLocalHold())
    }

    @Test("Two Use Local answers each let go of only what they held")
    func eachAnswerReleasesOnlyItsOwn() {
        var pending: Set<SyncCategory> = [.courses, .courseColors, .courseNames, .assignments]
        var hold = SyncConflicts.UseLocalHold()
        let first = hold.take([.courses, .courseColors], keepLocal: true, from: &pending)
        let second = hold.take([.assignments], keepLocal: true, from: &pending)

        hold.release(second, from: &pending)

        #expect(pending == [.courses, .courseColors, .courseNames])
        #expect(hold.held == first)
    }

    @Test("Names a sync left for a pending colours check stay unrecorded, so switching them off and on checks nothing")
    func namesHeldForAColoursCheckAreNotRecorded() async {
        await Self.withSyncProgress {
            Defaults[.categoriesSyncedOnce] = Self.categories.subtracting([.courseNames])
            Defaults[.pendingConflictCategories] = [.courseColors]

            Self.recordSync(pendingChecks: Defaults[.pendingConflictCategories])
            SyncConflicts.markForReenableCheck(.courseNames, signedIn: true, for: testSignIn)

            #expect(!SyncConflicts.hasSynced(.courseNames))
            #expect(Defaults[.pendingConflictCategories] == [.courseColors])
        }
    }

    @Test("Marks a sync left for an edit made during its fetch stay unrecorded")
    func marksLeftForAnEditAreNotRecorded() async {
        await Self.withSyncProgress {
            Self.recordSync(marksLeftFor: .editedDuringFetch)

            #expect(Self.synced == Self.categories.subtracting([.assignments]))
        }
    }

    @Test("A full sync records the categories it took, and a sign-out forgets them")
    func aFullSyncRecordsItsCategoriesAndASignOutForgetsThem() async {
        await Self.withSyncProgress {
            Self.recordSync()
            Defaults[.courseRowIdsSeen] = ["1151:CS1": 1]

            #expect(Self.synced == Self.categories)
            #expect(Defaults[.lastSeenCoursesResetAt] == Date.distantPast)

            SyncProgress.forget()

            #expect(Self.synced.isEmpty)
            #expect(Defaults[.courseRowIdsSeen].isEmpty)
        }
    }

    @Test("A full sync with a category's switch off takes none of its data, so switching it back on checks nothing for it",
          arguments: SyncCategory.allCases)
    func aSyncWithASwitchOffLeavesItsCategoryUnchecked(category: SyncCategory) async {
        await Self.withSyncProgress {
            for entry in Self.switches where entry.category == category { Defaults[entry.key] = false }
            Self.recordSync(marksLeftFor: SyncPolicy.reasonToLeaveMarks(
                syncsMarks: Defaults[.syncAssignments], conflictCheckPending: false,
                uploadedLocalMarks: false, editedDuringFetch: false
            ))

            for name in Self.categories { SyncConflicts.markForReenableCheck(name, signedIn: true, for: testSignIn) }

            #expect(Defaults[.pendingConflictCategories] == Self.categories.subtracting([category]))
        }
    }

    @Test("A full sync that read the Assignments switch off before its fetch takes no marks, though the switch is on by its end")
    func aSyncThatLeftTheMarksLeavesThemUnchecked() async {
        await Self.withSyncProgress {
            Self.recordSync(marksLeftFor: .switchedOff)

            #expect(Self.synced == Self.categories.subtracting([.assignments]))
        }
    }

    @Test("After a sign-out and a sign-in, turning TigerSync on raises no check, and the first pull takes the server's marks")
    func turningSyncOnAfterASignInChecksNothing() async {
        await Self.withSyncProgress {
            Defaults[.assignmentMarksSyncedOnce] = true
            Self.recordSync()

            SyncProgress.forget()
            for category in Self.categories { SyncConflicts.markForReenableCheck(category, signedIn: true, for: testSignIn) }

            #expect(Defaults[.pendingConflictCategories].isEmpty)
            #expect(SyncPolicy.reasonToLeaveMarks(
                syncsMarks: true,
                conflictCheckPending: Defaults[.pendingConflictCategories].contains(.assignments),
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

            for category in Self.categories { SyncConflicts.markForReenableCheck(category, signedIn: true, for: testSignIn) }

            #expect(Defaults[.pendingConflictCategories] == Self.categories)
        }
    }

    @Test("Switching a category back on while signed out marks nothing for whoever signs in next")
    func signedOutMarksNothing() async {
        await Self.withSyncProgress {
            Defaults[.assignmentMarksSyncedOnce] = true
            Self.recordSync()

            for category in Self.categories { SyncConflicts.markForReenableCheck(category, signedIn: false, for: testSignIn) }

            #expect(Defaults[.pendingConflictCategories].isEmpty)
        }
    }
}
