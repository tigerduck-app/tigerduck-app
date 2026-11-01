import Defaults
import Foundation

/// What the school account's sync has done so far; a write lands only in the sign-in it names.
@MainActor
enum SyncProgress {
    static func recordFullSync(coursesReset: Date, taken: Set<SyncCategory>, for signIn: SignIn) {
        Defaults[.lastSeenCoursesResetAt, for: signIn] = coursesReset
        Defaults[.categoriesSyncedOnce, for: signIn].formUnion(taken)
    }

    static func noteCoursesReset(_ remember: Date?, for signIn: SignIn) {
        Defaults[.lastSeenCoursesResetAt, for: signIn] = remember
    }

    static func noteMarksSynced(for signIn: SignIn) {
        Defaults[.assignmentMarksSyncedOnce, for: signIn] = true
    }

    static func noteCourseRows(_ rows: [String: Int], for signIn: SignIn) {
        Defaults[.courseRowIdsSeen, for: signIn] = rows
    }

    @discardableResult
    static func changePendingConflicts<Value>(for signIn: SignIn, _ change: (inout Set<SyncCategory>) -> Value) -> Value? {
        guard signIn.isCurrent else { return nil }
        return change(&Defaults[.pendingConflictCategories, for: signIn])
    }

    static func forget() {
        Defaults.reset(
            .pendingConflictCategories, .assignmentMarksSyncedOnce, .lastSeenCoursesResetAt, .categoriesSyncedOnce,
            .courseRowIdsSeen
        )
    }
}
