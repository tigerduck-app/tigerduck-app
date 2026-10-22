import Foundation

enum SemesterAttributionCacheMigration {
    private static let doneKey = "SemesterAttributionCacheMigration.v1.done"

    static func runIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: doneKey) }
        DataCache.shared.clearCourseCaches()
        CourseSelectionService.invalidateEnrolledCoursesCache()
    }
}
