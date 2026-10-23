import Defaults
import Foundation
import Testing
@testable import TigerDuck

private let doneKey = "SyncedAccountSeedMigration.v1.done"

@MainActor
struct SyncedAccountSeedMigrationTests {
    private static let categories: Set<String> = ["courses", "course_colors", "course_names", "assignments"]
    private static let switches: [Defaults.Key<Bool>] = [
        .syncCourses, .syncCourseColors, .syncCourseNames, .syncAssignments,
    ]

    private static var synced: Set<String> { categories.filter { AppState.hasSynced($0) } }

    private static func withUpdatedInstall(_ body: () -> Void) async {
        await withExclusiveRealDefaults {
            let saved = (
                Defaults[.categoriesSyncedOnce], Defaults[.pendingConflictCategories],
                Defaults[.assignmentMarksSyncedOnce], Defaults[.lastSeenCoursesResetAt]
            )
            let savedSwitches = switches.map { ($0, Defaults[$0]) }
            let savedDone = UserDefaults.standard.object(forKey: doneKey)
            defer {
                Defaults[.categoriesSyncedOnce] = saved.0
                Defaults[.pendingConflictCategories] = saved.1
                Defaults[.assignmentMarksSyncedOnce] = saved.2
                Defaults[.lastSeenCoursesResetAt] = saved.3
                for (key, value) in savedSwitches { Defaults[key] = value }
                if let savedDone {
                    UserDefaults.standard.set(savedDone, forKey: doneKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: doneKey)
                }
            }
            UserDefaults.standard.removeObject(forKey: doneKey)
            Defaults[.categoriesSyncedOnce] = []
            Defaults[.pendingConflictCategories] = []
            Defaults[.assignmentMarksSyncedOnce] = false
            Defaults[.lastSeenCoursesResetAt] = nil
            for key in switches { Defaults[key] = true }
            body()
        }
    }

    @Test("An install signed in at the update counts every category as synced, its switches off too, and only that launch decides")
    func signedInAtTheUpdateCountsEveryCategoryOnce() async {
        await Self.withUpdatedInstall {
            Defaults[.syncCourseNames] = false

            SyncedAccountSeedMigration.runIfNeeded(signedIn: true)

            #expect(Self.synced == ["courses", "course_colors", "course_names", "assignments"])

            Defaults[.categoriesSyncedOnce] = []
            SyncedAccountSeedMigration.runIfNeeded(signedIn: true)

            #expect(Self.synced.isEmpty)
        }
    }

    @Test("An install signed out at the update, as a fresh install reads, drops the checks a sign-out left and counts nothing as synced, even after a later sign-in")
    func signedOutAtTheUpdateDropsLeftChecksAndCountsNothing() async {
        await Self.withUpdatedInstall {
            Defaults[.pendingConflictCategories] = ["assignments"]

            SyncedAccountSeedMigration.runIfNeeded(signedIn: false)

            #expect(Defaults[.pendingConflictCategories].isEmpty)
            #expect(Self.synced.isEmpty)

            SyncedAccountSeedMigration.runIfNeeded(signedIn: true)

            #expect(Self.synced.isEmpty)
        }
    }

    @Test("Turning TigerSync back on before the first sync since the update checks every category of an account signed in at the update")
    func signedInAtTheUpdateKeepsTheReenableCheck() async {
        await Self.withUpdatedInstall {
            Defaults[.pendingConflictCategories] = ["courses"]

            SyncedAccountSeedMigration.runIfNeeded(signedIn: true)

            #expect(Defaults[.pendingConflictCategories] == ["courses"])

            for category in Self.categories { AppState.markForReenableCheck(category, signedIn: true) }

            #expect(Defaults[.pendingConflictCategories] == Self.categories)
        }
    }
}
