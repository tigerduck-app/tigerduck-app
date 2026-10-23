import Foundation

enum CourseColorPickSeedMigration {
    private static let doneKey = "CourseColorPickSeedMigration.v1.done"

    static func runIfNeeded(cache: DataCache = .shared) {
        guard !UserDefaults.standard.bool(forKey: doneKey),
              let colors = cache.loadCourseColorMapIfReadable() else { return }
        cache.savePickedCourseColors(cache.loadPickedCourseColors().union(colors.keys))
        UserDefaults.standard.set(true, forKey: doneKey)
    }
}
