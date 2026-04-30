import Foundation

/// One-shot migration: drops cached `courses_<semester>.json` files written by
/// builds before the raw-classroom cache existed in `NameAbbrService`. Those
/// caches may have stored `classroomMapJSON` values that were already
/// abbreviated (pinyin / translated / shortened), so toggling display modes
/// after upgrade would not round-trip through the JSON dictionary keyed by raw
/// Mandarin names. Clearing forces the next course fetch to repopulate both the
/// on-disk cache and the in-memory raw classroom map.
enum ClassroomAbbrCacheMigration {
    private static let doneKey = "ClassroomAbbrCacheMigration.v1.done"

    static func runIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: doneKey) }
        DataCache.shared.clearCourseCaches()
    }
}
