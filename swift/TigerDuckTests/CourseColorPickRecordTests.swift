import Foundation
import Testing
@testable import TigerDuck

struct CourseColorPickRecordTests {
    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [String: UInt32]
        private var picks: Set<String> = []

        init(map: [String: UInt32]) { self.map = map }

        func read() -> [String: UInt32]? { lock.withLock { map } }
        func write(_ next: [String: UInt32]) { lock.withLock { map = next } }
        func notePick(_ courseNo: String) { lock.withLock { _ = picks.insert(courseNo) } }
        func forgetPicks() { lock.withLock { picks = [] } }
        var picked: Set<String> { lock.withLock { picks } }
    }

    private static let palette = TigerDuckTheme.coursePaletteHexes

    private static func makeState(_ store: Store) -> ColorState {
        ColorState(
            load: { store.read() }, save: { store.write($0) },
            notePick: { store.notePick($0) }, forgetPicks: { store.forgetPicks() },
            protectedDataAvailable: { true }
        )
    }

    private static func folders(at root: URL) -> CacheFolders {
        CacheFolders(
            cache: root.appendingPathComponent("cache", isDirectory: true),
            persistent: root.appendingPathComponent("persistent", isDirectory: true)
        )
    }

    private static func makeColors(at root: URL) -> CourseColorFiles {
        CourseColorFiles(folders: folders(at: root))
    }

    @Test("a pick is noted for its course, not for the course it moves off that colour")
    func aPickIsNotedForItsCourseOnly() throws {
        let store = Store(map: [:])
        let state = Self.makeState(store)
        state.ensureAssignments(courseNos: ["CS1010001", "CS1010002"], palette: Self.palette)
        let taken = try #require(store.read()?["CS1010002"])

        let changed = state.setColor(hex: taken, for: "CS1010001", palette: Self.palette)

        #expect(Set(changed.keys) == ["CS1010001", "CS1010002"])
        #expect(store.picked == ["CS1010001"])
    }

    @Test("generated colours, the server's and a pick of the colour a course has already are no picks")
    func onlyAPickThatChangesAColourIsNoted() {
        let store = Store(map: [:])
        let state = Self.makeState(store)
        state.ensureAssignments(courseNos: ["CS1010001"], palette: Self.palette)
        _ = state.applyColors([("CS1010002", 0x123456)], palette: Self.palette)

        _ = state.setColor(hex: state.hex(for: "CS1010001", palette: Self.palette), for: "CS1010001", palette: Self.palette)

        #expect(store.picked.isEmpty)
    }

    @Test("reassigning every colour forgets the picks")
    func reassigningForgetsThePicks() {
        let store = Store(map: ["CS1010001": 0x123456])
        let state = Self.makeState(store)
        _ = state.setColor(hex: 0x654321, for: "CS1010001", palette: Self.palette)
        #expect(store.picked == ["CS1010001"])

        state.reassignAll(courseNos: ["CS1010001"], palette: Self.palette)

        #expect(store.picked.isEmpty)
    }

    @Test("the picks outlive a relaunch and go with the account's colours at a sign-out")
    @MainActor
    func thePicksFollowTheAccount() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CourseColorPickRecordTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        Self.makeColors(at: root).notePickedCourseColor("CS1010001")
        Self.makeColors(at: root).notePickedCourseColor("CS1010002")
        #expect(Self.makeColors(at: root).loadPickedCourseColors() == ["CS1010001", "CS1010002"])

        TestCache(folders: Self.folders(at: root)).forgetAccount()

        #expect(Self.makeColors(at: root).loadPickedCourseColors().isEmpty)
    }

    @Test("a colour map emptied here leaves no picks")
    func anEmptiedMapLeavesNoPicks() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CourseColorPickRecordTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let colors = Self.makeColors(at: root)
        colors.saveCourseColorMap(["CS1010001": 0x123456])
        colors.notePickedCourseColor("CS1010001")

        colors.saveCourseColorMap(["CS1010001": 0x654321])
        #expect(colors.loadPickedCourseColors() == ["CS1010001"])
        colors.saveCourseColorMap([:])

        #expect(colors.loadPickedCourseColors().isEmpty)
    }
}
