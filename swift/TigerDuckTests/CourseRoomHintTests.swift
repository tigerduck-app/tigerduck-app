import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct CourseRoomHintTests {

    @Test("short building-and-number codes are previewable")
    func acceptsShortCodes() {
        for room in ["TR-313", "E1-134", "AU-101", "IB-409-1", "E1-170-1", "T4 R 313"] {
            #expect(CourseRoomHint.isShortCode(room), "expected \(room) to be previewable")
        }
    }

    @Test("Chinese building-and-number rooms are previewable")
    func acceptsChineseCodes() {
        for room in ["共101", "博雅205", "管二304", "人文B106", "電二143",
                     "霖研一1501", "人文B114-1", "農化二B10-1", "文16"] {
            #expect(CourseRoomHint.isShortCode(room), "expected \(room) to be previewable")
        }
    }

    @Test("rooms that would not fit the cell are dropped")
    func rejectsEverythingElse() {
        for room in [
            "",
            "Heping Cheng 101",
            "Gongguan Track and Field Ground",
            "系上自行安排",
            "林一",
            "體育-游泳池",
            "綜合-大講堂",
            "綜合大講堂",
            "115研討室",
            "IB-1006",
            "TR-313, TR-409",
        ] {
            #expect(!CourseRoomHint.isShortCode(room), "expected \(room) to be dropped")
        }
    }

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
        #expect(CourseRoomHint.room(for: course, weekday: 5, periodId: "2") == nil)
    }

    @Test("an unmapped slot does not borrow the other block's room")
    func doesNotBorrowAnotherBlocksRoom() {
        let course = SDCourse(
            courseNo: "TEST0002",
            courseName: "Test",
            classroom: "TR-313",
            schedule: [1: ["3", "4", "6", "7"]],
            classroomMap: ["1-3": "TR-313", "1-4": "TR-313"]
        )
        #expect(CourseRoomHint.room(for: course, weekday: 1, periodId: "3") == "TR-313")
        #expect(CourseRoomHint.room(for: course, weekday: 1, periodId: "6") == nil)
    }

    @Test("a course with no map falls back to its flat classroom")
    func fallsBackWhenNoMapExists() {
        let course = SDCourse(
            courseNo: "TEST0003",
            courseName: "Test",
            classroom: "TR-313",
            schedule: [1: ["3"]]
        )
        #expect(CourseRoomHint.room(for: course, weekday: 1, periodId: "3") == "TR-313")
    }
}
