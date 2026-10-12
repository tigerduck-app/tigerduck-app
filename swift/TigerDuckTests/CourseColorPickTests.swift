// A colour pick moves another course off the picked colour (`TigerDuckTheme.assigning`). Only
// the picked course used to be sent, so the server kept two courses on one colour, and applying
// its colours row by row swapped the pair back and forth between syncs.
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct CourseColorPickTests {
    private static let red: UInt32 = 0xFF6B6B
    private static let teal: UInt32 = 0x4ECDC4

    @Test("A pick moves the course holding that colour, and reports both as changed")
    func pickReportsTheDisplacedCourse() {
        let before = ["CS1": Self.red, "CS2": Self.teal]

        let result = TigerDuckTheme.assigning(Self.teal, to: "CS1", in: before)

        #expect(result.map["CS1"] == Self.teal)
        #expect(result.map["CS2"] != Self.teal)
        #expect(Set(result.map.values).count == result.map.count)
        #expect(Set(result.changed.keys) == ["CS1", "CS2"])
        #expect(result.changed["CS2"] == result.map["CS2"])
    }

    @Test("Picking the colour a course already has changes nothing")
    func samePickChangesNothing() {
        let result = TigerDuckTheme.assigning(Self.red, to: "CS1", in: ["CS1": Self.red])
        #expect(result.changed.isEmpty)
    }

    @Test("A pick sends the picked course and every course it moved, skipping one with no Moodle id")
    func pickSendsEveryChangedCourse() {
        let overrides = AppState.courseColorOverrides(
            ["CS1": Self.teal, "CS2": Self.red, "MANUAL": 0x123456],
            moodleIds: ["CS1": "1151CS1", "CS2": "1151CS2"]
        )
        #expect(overrides.map(\.moodleId) == ["1151CS1", "1151CS2"])
        #expect(overrides.map(\.colorHex) == ["#4ECDC4", "#FF6B6B"])
    }

    @Test("Server colours apply oldest first, so where two courses share one the latest pick keeps it")
    func serverColoursApplyOldestFirst() {
        let rows: [[String: Any]] = [
            ["moodle_id": "1151CS2", "color_hex": "#FF6B6B", "color_hex_updated_at": "2026-10-12T08:00:00.654321+00:00"],
            ["moodle_id": "1151CS1", "color_hex": "#FF6B6B", "color_hex_updated_at": "2026-10-12T07:59:59.123456+00:00"],
            ["moodle_id": "1151CS3", "color_hex": "#4ECDC4"],
            ["moodle_id": "1151CS4", "color_hex": ""],
        ]
        let courseNos = ["1151CS1": "CS1", "1151CS2": "CS2", "1151CS3": "CS3", "1151CS4": "CS4"]

        let ordered = AppState.serverCourseColors(rows, courseNos: courseNos)
        #expect(ordered.map(\.courseNo) == ["CS3", "CS1", "CS2"])

        let apply = { (start: [String: UInt32]) in
            ordered.reduce(start) { TigerDuckTheme.assigning($1.hex, to: $1.courseNo, in: $0).map }
        }
        let once = apply([:])
        #expect(once["CS2"] == Self.red)
        #expect(once["CS1"] != Self.red)
        #expect(apply(once) == once)
    }

    @Test("With every preset taken, applying the same server colours again changes nothing")
    func exhaustedPaletteStaysStable() {
        var start: [String: UInt32] = [:]
        for (index, hex) in TigerDuckTheme.coursePaletteHexes.enumerated() {
            start[String(format: "XX%02d", index)] = hex
        }
        // Two rows sharing a colour, the later pick last.
        let rows: [(courseNo: String, hex: UInt32)] = [("CS1", Self.red), ("CS2", Self.red)]
        let apply = { (map: [String: UInt32]) in
            rows.reduce(map) { TigerDuckTheme.assigning($1.hex, to: $1.courseNo, in: $0).map }
        }

        let once = apply(start)

        #expect(once["CS2"] == Self.red)
        #expect(Set(once.values).count == once.count)
        #expect(apply(once) == once)
        #expect(apply(start) == once)
    }

    @Test("A displaced course merged from another device is found among the manual rows")
    func displacedMergedCourseHasAnId() {
        let picked = SDCourse(courseNo: "CS1", courseName: "CS1", moodleIdNumber: "1151CS1")
        let enrolled = SDCourse(courseNo: "CS2", courseName: "CS2", moodleIdNumber: "1151CS2")
        let merged = SDCourse(courseNo: "CS3", courseName: "CS3", moodleIdNumber: "1151CS3", semester: "1151")
        let manual = SDCourse(courseNo: "CS4", courseName: "CS4", semester: "1151")

        let ids = AppState.moodleIdsByCourseNo(picked: picked, termCourses: [enrolled], userAdded: [merged, manual])

        #expect(ids == ["CS1": "1151CS1", "CS2": "1151CS2", "CS3": "1151CS3"])
    }
}

