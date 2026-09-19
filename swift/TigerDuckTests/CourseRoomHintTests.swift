import Foundation
import Testing
@testable import TigerDuck

/// The timetable prints a room in the corner of a cell only when the room is
/// short enough to survive there. The gate is a pattern match, so these pin
/// both sides of it: the codes that must appear, and the prose NTUST also
/// files under "classroom" that must not.
@MainActor
struct CourseRoomHintTests {

    @Test("short building-and-number codes are previewable")
    func acceptsShortCodes() {
        for room in ["TR-313", "E1-134", "AU-101", "IB-409-1", "E1-170-1", "T4 R 313"] {
            #expect(CourseRoomHint.isShortCode(room), "expected \(room) to be previewable")
        }
    }

    @Test("rooms that would not fit the cell are dropped")
    func rejectsEverythingElse() {
        for room in [
            "",                      // no room recorded
            "Heping Cheng 101",      // NTNU prose form
            "Gongguan Track and Field Ground",
            "系上自行安排",            // "ask the department"
            "博雅205",                // Chinese building + number
            "IB-1006",               // four-digit room
            "TR-313, TR-409",        // two rooms in one slot
        ] {
            #expect(!CourseRoomHint.isShortCode(room), "expected \(room) to be dropped")
        }
    }

    /// A per-slot room wins over the day-level aggregate, so a course that
    /// meets twice on one day in two rooms still labels each block with its
    /// own room instead of falling back to the joined pair (which the gate
    /// would then reject).
    @Test("per-slot room beats the day aggregate")
    func prefersTheSlotRoom() {
        let course = SDCourse(
            courseNo: "TEST0001",
            courseName: "Test",
            classroom: "TR-313, TR-409",
            schedule: [1: ["3", "4"], 3: ["6"]],
            classroomMap: ["1-3": "TR-313", "1-4": "TR-313", "3-6": "TR-409"]
        )
        #expect(CourseRoomHint.room(for: course, weekday: 1, periodId: "3") == "TR-313")
        #expect(CourseRoomHint.room(for: course, weekday: 3, periodId: "6") == "TR-409")
        // Nothing mapped for this slot, and the flat fallback is two rooms.
        #expect(CourseRoomHint.room(for: course, weekday: 5, periodId: "2") == nil)
    }
}
