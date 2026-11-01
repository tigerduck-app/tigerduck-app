import Defaults
import Foundation

/// What the school account's sync has done so far; a write lands only in the sign-in it names.
@MainActor
enum SyncProgress {
    static func recordFullSync(coursesReset: Date, taken: Set<String>, for signIn: SignIn) {
        guard signIn.isCurrent else { return }
        Defaults[.lastSeenCoursesResetAt] = coursesReset
        Defaults[.categoriesSyncedOnce].formUnion(taken)
    }

    static func noteCoursesReset(_ remember: Date?, for signIn: SignIn) {
        guard signIn.isCurrent else { return }
        Defaults[.lastSeenCoursesResetAt] = remember
    }

    static func noteMarksSynced(for signIn: SignIn) {
        guard signIn.isCurrent else { return }
        Defaults[.assignmentMarksSyncedOnce] = true
    }

    static func noteCourseRows(_ rows: [String: Int], for signIn: SignIn) {
        guard signIn.isCurrent else { return }
        Defaults[.courseRowIdsSeen] = rows
    }

    @discardableResult
    static func changePendingConflicts<Value>(for signIn: SignIn, _ change: (inout Set<String>) -> Value) -> Value? {
        guard signIn.isCurrent else { return nil }
        return change(&Defaults[.pendingConflictCategories])
    }

    static func forget() {
        Defaults[.pendingConflictCategories] = []
        Defaults[.assignmentMarksSyncedOnce] = false
        Defaults[.lastSeenCoursesResetAt] = nil
        Defaults[.categoriesSyncedOnce] = []
        Defaults[.courseRowIdsSeen] = [:]
    }
}
