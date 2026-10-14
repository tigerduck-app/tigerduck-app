import Foundation
import Testing
@testable import TigerDuck

/// `course_color_map.json` is `completeFileProtectionUnlessOpen`, so a first read behind the lock
/// screen finds a file it cannot open. Read as an empty map, the next colour assignment would write
/// fresh colours over the user's (https://github.com/tigerduck-app/tigerduck-app/issues/442).
struct CourseColorMapLockedTests {
    /// The map file, readable or not, counting what is written to it.
    private final class Disk: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String: UInt32]
        private var locked = true
        private(set) var writes = 0

        init(stored: [String: UInt32]) { self.stored = stored }

        func read() -> [String: UInt32]? { lock.withLock { locked ? nil : stored } }
        func write(_ map: [String: UInt32]) { lock.withLock { stored = map; writes += 1 } }
        func unlock() { lock.withLock { locked = false } }
    }

    private static let palette = TigerDuckTheme.coursePaletteHexes

    @Test func aMapThatCannotBeReadYetIsNotWrittenOver() {
        let disk = Disk(stored: ["CS1010001": 0x123456])
        let state = ColorState(load: { disk.read() }, save: { disk.write($0) })

        state.ensureAssignments(courseNos: ["CS1010001", "CS1010002"], palette: Self.palette)
        _ = state.setColor(hex: 0x654321, for: "CS1010002", palette: Self.palette)
        #expect(!state.applyColors([("CS1010001", 0x777777)], palette: Self.palette))
        #expect(disk.writes == 0)

        disk.unlock()
        #expect(state.hex(for: "CS1010001", palette: Self.palette) == 0x123456)
    }

    @Test func aFileThatExistsButCannotBeOpenedReadsAsNotReadYet() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CourseColorMapLockedTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = DataCache(
            cacheDir: root.appendingPathComponent("cache", isDirectory: true),
            persistentDir: root.appendingPathComponent("persistent", isDirectory: true)
        )
        #expect(cache.loadCourseColorMapIfReadable() == [:])

        cache.saveCourseColorMap(["CS1010001": 0x123456])
        #expect(cache.loadCourseColorMapIfReadable() == ["CS1010001": 0x123456])

        // Mode 000 stands in for the lock screen: the file is there and does not open.
        let file = root.appendingPathComponent("persistent/course_color_map.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        #expect(cache.loadCourseColorMapIfReadable() == nil)
    }
}
