import Foundation
import Testing
@testable import TigerDuck

/// `course_color_map.json` is `completeFileProtectionUnlessOpen`, so a first read behind the lock
/// screen finds a file it cannot open. Read as an empty map, the next colour assignment would write
/// fresh colours over the user's (https://github.com/tigerduck-app/tigerduck-app/issues/442).
struct CourseColorMapLockedTests {
    private final class Disk: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String: UInt32]
        private var locked = true
        private(set) var writes = 0

        init(stored: [String: UInt32]) { self.stored = stored }

        var contents: [String: UInt32] { lock.withLock { stored } }
        func read() -> [String: UInt32]? { lock.withLock { locked ? nil : stored } }
        func write(_ map: [String: UInt32]) { lock.withLock { stored = map; writes += 1 } }
        func unlock() { lock.withLock { locked = false } }
        func relock() { lock.withLock { locked = true } }
    }

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date(timeIntervalSince1970: 1_790_000_000)

        var now: Date { lock.withLock { current } }
        func advance() { lock.withLock { current += ColorState.unreadableReadSpacing } }
    }

    private static let palette = TigerDuckTheme.coursePaletteHexes

    private static func makeState(_ disk: Disk, clock: TestClock, unlocked: Bool) -> ColorState {
        ColorState(
            load: { disk.read() }, save: { disk.write($0) }, notePick: { _ in }, forgetPicks: {},
            protectedDataAvailable: { unlocked }, now: { clock.now }
        )
    }

    @Test func aMapThatCannotBeReadYetIsNotWrittenOver() {
        let disk = Disk(stored: ["CS1010001": 0x123456])
        let state = Self.makeState(disk, clock: TestClock(), unlocked: false)

        state.ensureAssignments(courseNos: ["CS1010001", "CS1010002"], palette: Self.palette)
        _ = state.setColor(hex: 0x654321, for: "CS1010002", palette: Self.palette)
        #expect(!state.applyColors([("CS1010001", 0x777777)], palette: Self.palette))
        #expect(disk.writes == 0)

        disk.unlock()
        #expect(state.hex(for: "CS1010001", palette: Self.palette) == 0x123456)
    }

    @Test func readsBehindTheLockScreenNeverGiveUpOnTheMap() {
        let disk = Disk(stored: ["CS1010001": 0x123456])
        let clock = TestClock()
        let state = Self.makeState(disk, clock: clock, unlocked: false)

        for _ in 0..<(2 * ColorState.unreadableReadLimit) {
            _ = state.setColor(hex: 0x654321, for: "CS1010002", palette: Self.palette)
            clock.advance()
        }

        #expect(disk.writes == 0)
    }

    @Test func aMapUnreadableWhileUnlockedIsGivenUpOnAndReplaced() {
        let disk = Disk(stored: ["CS1010001": 0x123456])
        let clock = TestClock()
        let state = Self.makeState(disk, clock: clock, unlocked: true)

        for _ in 0..<10 { _ = state.hex(for: "CS1010001", palette: Self.palette) }
        for _ in 2..<ColorState.unreadableReadLimit {
            clock.advance()
            _ = state.setColor(hex: 0x654321, for: "CS1010002", palette: Self.palette)
        }
        #expect(disk.writes == 0)

        clock.advance()
        _ = state.setColor(hex: 0x654321, for: "CS1010002", palette: Self.palette)
        #expect(disk.contents == ["CS1010002": 0x654321])
    }

    @Test func aReloadAfterGivingUpStaysGivenUp() {
        let disk = Disk(stored: ["CS1010001": 0x123456])
        let clock = TestClock()
        let state = Self.makeState(disk, clock: clock, unlocked: true)
        for _ in 0..<ColorState.unreadableReadLimit {
            _ = state.snapshot()
            clock.advance()
        }

        state.reload()
        state.ensureAssignments(courseNos: ["CS1010002"], palette: Self.palette)

        #expect(disk.contents.keys.sorted() == ["CS1010002"])
    }

    @Test func aReadThatWorksStartsTheCountOver() {
        let disk = Disk(stored: ["CS1010001": 0x123456])
        let clock = TestClock()
        let state = Self.makeState(disk, clock: clock, unlocked: true)
        for _ in 1..<ColorState.unreadableReadLimit {
            _ = state.snapshot()
            clock.advance()
        }
        disk.unlock()
        #expect(state.snapshot() == ["CS1010001": 0x123456])

        disk.relock()
        state.reload()
        clock.advance()
        _ = state.setColor(hex: 0x654321, for: "CS1010002", palette: Self.palette)

        #expect(disk.writes == 0)
    }

    @Test func aSaveAfterGivingUpStartsTheCountOver() {
        let disk = Disk(stored: ["CS1010001": 0x123456])
        let clock = TestClock()
        let state = Self.makeState(disk, clock: clock, unlocked: true)
        for _ in 0..<ColorState.unreadableReadLimit {
            _ = state.snapshot()
            clock.advance()
        }
        _ = state.setColor(hex: 0x654321, for: "CS1010002", palette: Self.palette)
        #expect(disk.writes == 1)

        state.reload()
        clock.advance()
        state.ensureAssignments(courseNos: ["CS1010003"], palette: Self.palette)

        #expect(disk.writes == 1)
    }

    @Test func aFileThatExistsButCannotBeOpenedReadsAsNotReadYet() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CourseColorMapLockedTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let colors = CourseColorFiles(folders: CacheFolders(
            cache: root.appendingPathComponent("cache", isDirectory: true),
            persistent: root.appendingPathComponent("persistent", isDirectory: true)
        ))
        #expect(colors.loadCourseColorMapIfReadable() == [:])

        colors.saveCourseColorMap(["CS1010001": 0x123456])
        #expect(colors.loadCourseColorMapIfReadable() == ["CS1010001": 0x123456])

        // Mode 000 stands in for the lock screen: the file is there and does not open.
        let file = root.appendingPathComponent("persistent/course_color_map.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        #expect(colors.loadCourseColorMapIfReadable() == nil)
    }

    @Test func aMapThatDoesNotDecodeFallsBackToTheEarlierColours() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CourseColorMapLockedTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistent = root.appendingPathComponent("persistent", isDirectory: true)
        let colors = CourseColorFiles(folders: CacheFolders(
            cache: root.appendingPathComponent("cache", isDirectory: true), persistent: persistent
        ))
        try Data("not json".utf8).write(to: persistent.appendingPathComponent("course_color_map.json"))
        try Data(#"{"CS1010001":1}"#.utf8).write(to: persistent.appendingPathComponent("course_custom_colors.json"))

        #expect(colors.loadCourseColorMapIfReadable() == ["CS1010001": 0x4ECDC4])
    }
}
