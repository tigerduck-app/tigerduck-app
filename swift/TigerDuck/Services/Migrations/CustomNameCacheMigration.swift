import Foundation

/// One-shot migration: drops cached `courses_<semester>_<lang>.json` files
/// written by builds where the rename flow overwrote `SDCourse.courseName`
/// in place with the user's alias. After the customName overlay refactor,
/// those polluted cache entries would otherwise be treated as canonical —
/// so tapping "Revert to default" would clear `customName` but leave the
/// alias as `course.courseName`, with no way to recover the API name short
/// of a successful network refresh. Clearing forces the next course fetch
/// to repopulate the on-disk cache from the API.
///
/// Only the semester-scoped caches are touched here; `user_added_courses.json`
/// has no network refresh source and is handled defensively at load time
/// in `DataCache.loadUserAddedCourses`.
enum CustomNameCacheMigration {
    private static let doneKey = "CustomNameCacheMigration.v1.done"

    static func runIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: doneKey) }
        // Pollution can only exist if the user has at least one persisted
        // rename. Skipping the purge for users who never renamed a course
        // preserves their offline timetable across the upgrade — they
        // would otherwise see an empty class table on a cold launch with
        // no network until the next successful course fetch.
        guard !DataCache.shared.loadCourseCustomNames().isEmpty else { return }
        DataCache.shared.clearCourseCaches()
    }
}
