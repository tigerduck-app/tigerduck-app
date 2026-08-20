import Foundation

/// One-shot migration: drops cached `courses_<semester>.json` files written by
/// builds that filed 選課清單 enrolments under `currentSemesterCode()` instead
/// of the term the 選課 system was actually serving. Whenever NTUST opened a
/// term ahead of the month heuristic, the outgoing term's cache absorbed the
/// incoming term's courses and rendered both in one grid — see
/// ``SemesterCatalog``. Clearing forces the next fetch to rebuild each
/// semester from its own sources.
enum SemesterAttributionCacheMigration {
    private static let doneKey = "SemesterAttributionCacheMigration.v1.done"

    static func runIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: doneKey) }
        DataCache.shared.clearCourseCaches()
        // The enrolled-course-no cache is keyed by term too, and its entries
        // carry the same mis-attribution for up to 24h.
        CourseSelectionService.invalidateEnrolledCoursesCache()
    }
}
