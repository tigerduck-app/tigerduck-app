import Foundation
import Testing
@testable import TigerDuck

struct CourseBlockRoomTests {
    private static let map = [
        "1-3": "TR-313",
        "1-4": "TR-313、TR-314",
        "1-7": "IB-101",
    ]

    @Test func aBlockGetsTheDistinctRoomsOfItsPeriods() {
        let room = CourseBlockRoom.room(
            weekday: 1, periods: ["3", "4"], map: Self.map, fallback: "TR-313, TR-314, IB-101"
        )
        #expect(room == "TR-313, TR-314")
    }

    @Test func aBlockTheMapHasNoRoomForFallsBack() {
        #expect(CourseBlockRoom.room(weekday: 2, periods: ["3"], map: Self.map, fallback: "TR-313") == "TR-313")
        #expect(CourseBlockRoom.room(weekday: 1, periods: ["3"], map: [:], fallback: "TR-313") == "TR-313")
    }

    @Test func splitTrimsAndDropsEmptyParts() {
        #expect(CourseBlockRoom.split(" TR-313 ， IB-101,,") == ["TR-313", "IB-101"])
    }
}
