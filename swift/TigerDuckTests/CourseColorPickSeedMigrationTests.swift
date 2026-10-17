// The course colours from before the app noted which ones the user picked
// (https://github.com/tigerduck-app/tigerduck-app/issues/563). The done key mirrors the migration's
// private one, real process-wide state: the suite is `.serialized` and clears it.
import Foundation
import Testing
@testable import TigerDuck

private let doneKey = "CourseColorPickSeedMigration.v1.done"

@Suite(.serialized)
struct CourseColorPickSeedMigrationTests {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CourseColorPickSeedMigrationTests-\(UUID().uuidString)", isDirectory: true)

    init() {
        UserDefaults.standard.removeObject(forKey: doneKey)
    }

    private func makeCache() -> DataCache {
        DataCache(
            cacheDir: root.appendingPathComponent("cache", isDirectory: true),
            persistentDir: root.appendingPathComponent("persistent", isDirectory: true)
        )
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removeObject(forKey: doneKey)
    }

    @Test("every colour from before counts as picked, beside the picks noted since, and only once")
    func coloursFromBeforeCountAsPicked() {
        defer { cleanUp() }
        let cache = makeCache()
        cache.saveCourseColorMap(["CS1010001": 0x123456, "CS1010002": 0x654321])
        cache.notePickedCourseColor("CS1010003")

        CourseColorPickSeedMigration.runIfNeeded(cache: cache)
        #expect(cache.loadPickedCourseColors() == ["CS1010001", "CS1010002", "CS1010003"])

        cache.savePickedCourseColors([])
        CourseColorPickSeedMigration.runIfNeeded(cache: cache)
        #expect(cache.loadPickedCourseColors().isEmpty)
    }

    @Test("a colour map that cannot be read yet waits for a launch that can read it")
    func anUnreadableMapWaitsForALaterLaunch() throws {
        defer { cleanUp() }
        let cache = makeCache()
        cache.saveCourseColorMap(["CS1010001": 0x123456])
        // Mode 000 stands in for the lock screen: the file is there and does not open.
        let file = root.appendingPathComponent("persistent/course_color_map.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)

        CourseColorPickSeedMigration.runIfNeeded(cache: cache)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(cache.loadPickedCourseColors().isEmpty)

        CourseColorPickSeedMigration.runIfNeeded(cache: cache)
        #expect(cache.loadPickedCourseColors() == ["CS1010001"])
    }
}
