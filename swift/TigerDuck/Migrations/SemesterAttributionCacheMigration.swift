import Foundation

enum SemesterAttributionCacheMigration {
    private static let doneKey = "SemesterAttributionCacheMigration.v1.done"

    static func runIfNeeded() {
        guard !AppUserDefaults.standard.bool(forKey: doneKey) else { return }
        defer { AppUserDefaults.standard.set(true, forKey: doneKey) }
        CourseStore.shared.clearCourseCaches()
        CourseSelectionService.invalidateEnrolledCoursesCache()
    }
}
