import Foundation
import Testing
import UIKit
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

        CourseColorPickSeedMigration.runIfNeeded(cache: cache, center: NotificationCenter())
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(cache.loadPickedCourseColors().isEmpty)

        CourseColorPickSeedMigration.runIfNeeded(cache: cache)
        #expect(cache.loadPickedCourseColors() == ["CS1010001"])
    }

    /// Unlocking resumes the process that read the map as locked, so the seed cannot wait for the
    /// next launch: a sign-out before it would see no picks
    /// (https://github.com/tigerduck-app/tigerduck-app/issues/736).
    @Test(
        "a colour map that cannot be read yet is seeded once it can, without another launch",
        arguments: [UIApplication.protectedDataDidBecomeAvailableNotification, UIApplication.didBecomeActiveNotification]
    )
    @MainActor
    func anUnreadableMapIsSeededOnceItReads(readable: Notification.Name) throws {
        defer { cleanUp() }
        let cache = makeCache()
        let center = NotificationCenter()
        cache.saveCourseColorMap(["CS1010001": 0x123456])
        let file = root.appendingPathComponent("persistent/course_color_map.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)

        CourseColorPickSeedMigration.runIfNeeded(cache: cache, center: center)
        center.post(name: readable, object: nil)
        #expect(cache.loadPickedCourseColors().isEmpty)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        center.post(name: readable, object: nil)
        #expect(cache.loadPickedCourseColors() == ["CS1010001"])

        cache.savePickedCourseColors([])
        center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(cache.loadPickedCourseColors().isEmpty)
    }
}
