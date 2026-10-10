import Foundation

/// One-shot migration: drops cached `courses_<semester>_<lang>.json` files written by builds
/// whose rename flow overwrote `SDCourse.courseName` with the user's alias. With the
/// `customName` overlay those entries read as canonical, so "Revert to default" would clear
/// `customName` but leave the alias as `courseName` until a successful network refresh.
/// Clearing makes the next course fetch rebuild the cache from the API.
///
/// Only semester-scoped caches: `user_added_courses.json` has no network refresh source and is
/// handled at load time in `DataCache.loadUserAddedCourses`.
enum CustomNameCacheMigration {
    private static let doneKey = "CustomNameCacheMigration.v1.done"

    static func runIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: doneKey) }
        // Pollution needs at least one persisted rename. Skipping the purge for everyone else
        // keeps their offline timetable across the upgrade, instead of an empty class table on
        // a cold launch with no network until the next successful course fetch.
        guard !DataCache.shared.loadCourseCustomNames().isEmpty else { return }
        DataCache.shared.clearCourseCaches()
    }
}
