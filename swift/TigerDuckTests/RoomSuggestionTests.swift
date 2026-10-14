import Foundation
import Testing
@testable import TigerDuck

/// A made-up Wednesday on the main campus: the user has a class at periods 1-2 in TR-214, at
/// 5-6 in TR-309 and at 8-9 in IB-503. Rooms by period: `.` free, `c` a class, `b` booked.
struct RoomSuggestionTests {
    static let day: [String: String] = [
        "TR-209": "cccc.cc.cc....", "TR-210": "cc..cc..cc....", "TR-211": "cccc..cc......",
        "TR-212": "cc....cc..b...", "TR-213": "..c.cc..cc....", "TR-214": "cccccc........",
        "TR-309": "cc..cc..cc....", "TR-310-1": "cc............", "TR-311": "cc..b.cc..cc..",
        "TR-312": "ccccc..ccc....", "TR-313": "..cc..cc......", "TR-411": "..b...cc......",
        "TR-412-1": "cc.cc.........", "TR-510": "cccccccc......", "TR-611": "cc..cccc..cc..",
        "IB-305": "cc..cc..cc....", "IB-401": "cccc..cc......", "IB-503": "cc..cc.cc.....",
        "IB-505": "..........cccc", "IB-508": "..............", "IB-602-1": "cccccc..cc....",
        "T4-301": "cc..cc........", "T4-302": "cccccccc......", "T4-402": "....cc..cc....",
        "T4-404": "cc.c..........", "T3-301": "cccc..cc......", "T3-303": "..cc..........",
        "EE-311": "cc..cc..cccc..", "EE-406": "cccc....cc....", "E1-306": "cccccccccc....",
        "E2-102": "cc..cc........",
    ]

    static var rooms: [RoomUsage] {
        day.keys.sorted().map { room in
            RoomUsage(room: room, slots: day[room, default: ""].map { mark -> RoomSlotUse in
                switch mark {
                case ".": .free
                case "b": .booked
                default: .course(name: "課程", teacher: "")
                }
            })
        }
    }

    static func stop(_ course: String, _ room: String, _ periods: ClosedRange<Int>) -> ClassStop {
        ClassStop(
            course: course, room: room, place: RoomPlace(room: room),
            firstPeriod: periods.lowerBound, lastPeriod: periods.upperBound
        )
    }

    static let classes = [
        stop("計算機網路", "TR-214", 0...1),
        stop("作業系統", "TR-309", 4...5),
        stop("資料庫系統", "IB-503", 7...8),
    ]

    @Test("a free room in a building the walking model cannot place ranks after the ones it can")
    func unplacedBuildingRanksLast() throws {
        let unplaced = RoomUsage(room: "ME1-261", slots: Array(repeating: .free, count: 14))
        let suggestion = try #require(
            RoomSuggestion.make(rooms: Self.rooms + [unplaced], period: 2, classes: Self.classes, limit: 40)
        )

        #expect(suggestion.candidates.first?.room.room == "TR-309")
        #expect(suggestion.candidates.filter(\.fits).last?.room.room == "ME1-261")
    }

    @Test("a class in a building the walking model cannot place adds no walk, so the other class ranks the rooms")
    func unplacedClassAddsNoWalk() throws {
        let classes = [Self.stop("計算機網路", "ME1-201", 0...1), Self.stop("作業系統", "TR-309", 4...5)]
        let suggestion = try #require(RoomSuggestion.make(rooms: Self.rooms, period: 2, classes: classes))

        #expect(suggestion.candidates.first?.room.room == "TR-309")
    }

    @Test("between TR-214 and TR-309 the next class's own room comes first, one floor up and staying put")
    func betweenTwoClasses() throws {
        let suggestion = try #require(RoomSuggestion.make(rooms: Self.rooms, period: 2, classes: Self.classes))
        let best = try #require(suggestion.candidates.first)

        #expect(suggestion.candidates.map(\.room.room) == ["TR-309", "TR-310-1", "TR-212"])
        #expect(suggestion.previous?.room == "TR-214")
        #expect(suggestion.next?.room == "TR-309")
        #expect(RoomMove.between(suggestion.previous?.place, best.place) == .floors(1))
        #expect(RoomMove.between(best.place, suggestion.next?.place) == .sameRoom)
        #expect(best.fits)
        #expect(suggestion.freeSpan(of: best) == 2...3)
    }

    @Test("a room free until the next class ranks before a closer one taken sooner")
    func fittingFirst() throws {
        let suggestion = try #require(
            RoomSuggestion.make(rooms: Self.rooms, period: 2, classes: Self.classes, limit: 100)
        )
        let order = suggestion.candidates.map(\.room.room)
        let fitting = try #require(order.firstIndex(of: "TR-611"))
        let closer = try #require(order.firstIndex(of: "TR-412-1"))
        #expect(fitting < closer)
        #expect(suggestion.candidates.allSatisfy { $0.room.isFree(at: 2) })
    }

    @Test("the free span stops before the next class even when the room stays free")
    func spanStopsAtTheNextClass() throws {
        let suggestion = try #require(
            RoomSuggestion.make(rooms: Self.rooms, period: 2, classes: Self.classes, limit: 100)
        )
        let open = try #require(suggestion.candidates.first { $0.room.room == "TR-310-1" })
        #expect(open.freeUntil == 13)
        #expect(suggestion.freeSpan(of: open) == 2...3)
    }

    @Test("in class there is no suggestion")
    func inClass() {
        #expect(RoomSuggestion.make(rooms: Self.rooms, period: 4, classes: Self.classes) == nil)
        #expect(RoomSuggestion.make(rooms: Self.rooms, period: 8, classes: Self.classes) == nil)
    }

    @Test("after the last class the rooms near it lead, and the class's own room stays put")
    func onlyAPreviousClass() throws {
        let suggestion = try #require(RoomSuggestion.make(rooms: Self.rooms, period: 9, classes: Self.classes))
        let best = try #require(suggestion.candidates.first)

        #expect(suggestion.previous?.course == "資料庫系統")
        #expect(suggestion.next == nil)
        #expect(best.room.room == "IB-503")
        #expect(RoomMove.between(suggestion.previous?.place, best.place) == .sameRoom)
        #expect(!best.fits)
        #expect(suggestion.freeSpan(of: best) == 9...13)
    }

    @Test("before the first class the route leads to it")
    func onlyANextClass() throws {
        let classes = [Self.stop("作業系統", "TR-309", 4...5)]
        let suggestion = try #require(
            RoomSuggestion.make(rooms: Self.rooms, period: 2, classes: classes, limit: 100)
        )
        let best = try #require(suggestion.candidates.first)
        let below = try #require(suggestion.candidates.first { $0.room.room == "TR-212" })

        #expect(suggestion.previous == nil)
        #expect(best.room.room == "TR-309")
        #expect(RoomMove.between(best.place, suggestion.next?.place) == .sameRoom)
        #expect(RoomMove.between(below.place, suggestion.next?.place) == .floors(1))
    }

    @Test("no class that day, or none with a known room, gives no suggestion")
    func nothingToStartFrom() {
        #expect(RoomSuggestion.make(rooms: Self.rooms, period: 2, classes: []) == nil)
        let unplaced = [Self.stop("專題研究", "系上安排", 0...1), Self.stop("書報討論", "HHC-A304", 4...5)]
        #expect(RoomSuggestion.make(rooms: Self.rooms, period: 2, classes: unplaced) == nil)
    }
}
