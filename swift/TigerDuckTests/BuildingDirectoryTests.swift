import Foundation
import Testing
@testable import TigerDuck

struct BuildingDirectoryTests {
    private static let rooms = RoomSuggestionTests.rooms

    @Test("every building with rooms that day, with how many are free at the period")
    func buildings() {
        let directory = BuildingDirectory(rooms: Self.rooms, period: 2)
        #expect(directory.buildings.map(\.code) == ["E1", "E2", "EE", "IB", "T3", "T4", "TR"])
        let free = Dictionary(uniqueKeysWithValues: directory.buildings.map { ($0.code, $0.free.count) })
        #expect(free == ["E1": 0, "E2": 1, "EE": 1, "IB": 4, "T3": 0, "T4": 3, "TR": 7])
    }

    @Test("a building's free rooms by floor, lowest first, in room order")
    func floors() {
        let floors = BuildingDirectory(rooms: Self.rooms, period: 2).floors(of: "TR")
        #expect(floors.map(\.label) == ["2F", "3F", "4F", "6F"])
        #expect(floors.map { $0.rooms.map(\.room) } == [
            ["TR-210", "TR-212"],
            ["TR-309", "TR-310-1", "TR-311"],
            ["TR-412-1"],
            ["TR-611"],
        ])
        #expect(BuildingDirectory(rooms: Self.rooms, period: 2).floors(of: "T3").isEmpty)
    }

    @Test("the nearest two other buildings with a free room")
    func nearby() {
        let directory = BuildingDirectory(rooms: Self.rooms, period: 2)
        #expect(directory.nearby("T3").map(\.code) == ["T4", "TR"])
        #expect(directory.nearby("E1").map(\.code) == ["T4", "E2"])
    }

    @Test("the last pick while it has rooms that day, else the suggestion's building, else the most free rooms")
    func defaultBuilding() {
        let directory = BuildingDirectory(rooms: Self.rooms, period: 2)
        #expect(directory.defaultBuilding(picked: "T3", suggested: "IB") == "T3")
        #expect(directory.defaultBuilding(picked: "MA", suggested: "IB") == "IB")
        #expect(directory.defaultBuilding(picked: nil, suggested: nil) == "TR")
        #expect(BuildingDirectory(rooms: [], period: 2).defaultBuilding(picked: "TR", suggested: nil) == nil)
    }
}

@MainActor
struct ClassStopTests {
    private static let wednesday = AppConstants.taipeiCalendar.date(
        from: DateComponents(year: 2026, month: 10, day: 14, hour: 9)
    ) ?? .distantPast

    @Test("each block of a course is a stop at its periods and room, placed by the school's name")
    func stops() {
        let course = SDCourse(
            courseNo: "CS1001301",
            courseName: "計算機網路",
            classroom: "TR-214, Seminar 309",
            schedule: [3: ["1", "2", "6"]],
            classroomMap: ["3-1": "TR-214", "3-2": "TR-214", "3-6": "Seminar 309"]
        )
        let slots = CourseTimeSlot.meetingSlots(from: [course], on: Self.wednesday, isClassDay: { _ in true })

        let stops = ClassStop.stops(from: slots) { $0 == "Seminar 309" ? "TR-309" : $0 }

        #expect(stops.map(\.course) == ["計算機網路", "計算機網路"])
        #expect(stops.map(\.room) == ["TR-214", "Seminar 309"])
        #expect(stops.map(\.place?.floorLabel) == ["2F", "3F"])
        #expect(stops.map(\.firstPeriod) == [0, 5])
        #expect(stops.map(\.lastPeriod) == [1, 5])
    }

    @Test("a block that changes rooms halfway is a stop for each room")
    func aBlockThatChangesRoomsIsTwoStops() {
        let course = SDCourse(
            courseNo: "CS1001302",
            courseName: "作業系統",
            classroom: "TR-214, IB-305",
            schedule: [3: ["1", "2", "3", "4"]],
            classroomMap: ["3-1": "TR-214", "3-2": "TR-214", "3-3": "IB-305", "3-4": "IB-305"]
        )
        let slots = CourseTimeSlot.meetingSlots(from: [course], on: Self.wednesday, isClassDay: { _ in true })

        let stops = ClassStop.stops(from: slots) { $0 }

        #expect(stops.map(\.room) == ["TR-214", "IB-305"])
        #expect(stops.map(\.firstPeriod) == [0, 2])
        #expect(stops.map(\.lastPeriod) == [1, 3])
    }

    @Test("a block the school moved that day is a stop in the new room")
    func aMovedBlockStopsInItsNewRoom() throws {
        let course = SDCourse(
            courseNo: "CS1001303", courseName: "編譯器", classroom: "TR-214", schedule: [3: ["1", "2", "6"]]
        )
        let changes = try CourseChanges(json: JSONSerialization.data(withJSONObject: ["term": "1151", "changes": [
            ["id": 1, "course_no": "CS1001303", "kind": "room", "periods": ["1", "2"],
             "class_days": ["2026-10-14"], "room": "IB-305"],
        ]] as [String: Any]))
        let slots = CourseTimeSlot.meetingSlots(
            from: [course], on: Self.wednesday, isClassDay: { _ in true }, changes: changes
        )

        let stops = ClassStop.stops(from: slots) { $0 }

        #expect(stops.map(\.room) == ["IB-305", "TR-214"])
        #expect(stops.map(\.firstPeriod) == [0, 5])
    }

    @Test("a block the school moved to other hours that day is a stop at the periods it now meets")
    func aRetimedBlockStopsAtItsNewPeriods() throws {
        let course = SDCourse(
            courseNo: "CS1001304", courseName: "資料庫", classroom: "TR-214", schedule: [3: ["8"]]
        )
        let changes = try CourseChanges(json: JSONSerialization.data(withJSONObject: ["term": "1151", "changes": [
            ["id": 1, "course_no": "CS1001304", "kind": "start", "class_days": ["2026-10-14"], "start": "09:10"],
            ["id": 2, "course_no": "CS1001304", "kind": "end", "class_days": ["2026-10-14"], "end": "10:00"],
        ]] as [String: Any]))
        let slots = CourseTimeSlot.meetingSlots(
            from: [course], on: Self.wednesday, isClassDay: { _ in true }, changes: changes
        )

        let stops = ClassStop.stops(from: slots) { $0 }

        #expect(stops.map(\.room) == ["TR-214"])
        #expect(stops.map(\.firstPeriod) == [1])
        #expect(stops.map(\.lastPeriod) == [1])
    }
}
