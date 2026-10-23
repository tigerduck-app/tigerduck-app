import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct CourseOverrideHoldTests {
    private static let courseNos = ["1151CS1": "CS1", "1151CS2": "CS2"]

    @Test("A course whose colour is queued here keeps its own, and the others take the server's")
    func aQueuedColourIsLeftAsItIs() {
        let rows: [[String: Any]] = [
            ["moodle_id": "1151CS1", "color_hex": "#FF6B6B"],
            ["moodle_id": "1151CS2", "color_hex": "#4ECDC4"],
        ]

        let colors = AppState.serverCourseColors(rows, courseNos: Self.courseNos, holding: ["1151CS1"])

        #expect(colors.map(\.courseNo) == ["CS2"])
    }

    @Test("A course whose name is queued here keeps every language of its own, and the others take the server's")
    func aQueuedNameIsLeftAsItIs() {
        let rows: [[String: Any]] = [
            ["moodle_id": "1151CS1", "custom_names": ["en": "Old", "zh": "Older"]],
            ["moodle_id": "1151CS2", "custom_names": ["en": "Server", "zh": ""]],
        ]
        let local = ["CS1": ["en": "New"], "CS2": ["en": "Mine", "zh": "Gone"]]

        let names = AppState.courseNamesAfterPull(
            rows, courseNos: Self.courseNos, local: local, holding: ["1151CS1"]
        )

        #expect(names == ["CS1": ["en": "New"], "CS2": ["en": "Server"]])
    }

    @Test("Turning name sync back on reads a cleared server name as no name, not a conflict")
    func aClearedServerNameMatchesNoName() {
        let rows: [[String: Any]] = [
            ["moodle_id": "1151CS1", "custom_names": ["zh": ""]],
            ["moodle_id": "1151CS2", "custom_names": ["zh": "", "en": "X"]],
        ]

        let mismatches = AppState.courseNameMismatches(rows, courseNos: Self.courseNos, local: ["CS2": ["en": "X"]])

        #expect(mismatches.isEmpty)
    }

    @Test("Turning name sync back on still reports a name that differs, or one only this device has")
    func aDifferentNameIsAConflict() {
        let rows: [[String: Any]] = [["moodle_id": "1151CS1", "custom_names": ["zh": "", "en": "X"]]]

        let mismatches = AppState.courseNameMismatches(
            rows, courseNos: Self.courseNos, local: ["CS1": ["en": "Y"], "CS2": ["zh": "Z"]]
        )

        #expect(mismatches.count == 2)
    }
}
