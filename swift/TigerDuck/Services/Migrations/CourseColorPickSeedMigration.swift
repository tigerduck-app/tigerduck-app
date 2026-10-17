import Foundation

/// One-shot migration: counts each course colour from before the app noted which ones the user
/// picked as picked. A pick among them cannot be told from a generated colour, and counted as
/// generated it would go at a sign-out without the confirmation asking about it
/// (https://github.com/tigerduck-app/tigerduck-app/issues/563). A colour map that cannot be read
/// yet, as behind the lock screen, waits for a later launch. Keep while a device can still update
/// from 2.6.0 or earlier.
enum CourseColorPickSeedMigration {
    private static let doneKey = "CourseColorPickSeedMigration.v1.done"

    static func runIfNeeded(cache: DataCache = .shared) {
        guard !UserDefaults.standard.bool(forKey: doneKey),
              let colors = cache.loadCourseColorMapIfReadable() else { return }
        cache.savePickedCourseColors(cache.loadPickedCourseColors().union(colors.keys))
        UserDefaults.standard.set(true, forKey: doneKey)
    }
}
