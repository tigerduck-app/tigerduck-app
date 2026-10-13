import Foundation
import Testing
@testable import TigerDuck

struct RoomPlaceTests {
    private func place(_ room: String) throws -> RoomPlace {
        try #require(RoomPlace(room: room))
    }

    @Test("the hundreds of a room number give the floor, and 0 means B1")
    func roomNumbers() throws {
        #expect(try place("TR-214").building == "TR")
        #expect(try place("TR-214").floorLabel == "2F")
        #expect(try place("TR-309").floorLabel == "3F")
        #expect(try place("LB-001").floorLabel == "B1")
        #expect(try place("LB-001").level == 0)
        #expect(try place("MA-010").floorLabel == "B1")
        #expect(try place("IB-1006").floorLabel == "10F")
        #expect(try place("T2-405-3").floorLabel == "4F")
    }

    @Test("a part of a room stays on the room's floor")
    func roomParts() throws {
        #expect(try place("TR-310-1").floorLabel == "3F")
        #expect(try place("TR-310-1").number == 310)
        #expect(try place("RB-809A").floorLabel == "8F")
        #expect(try place("RB-708(C1)(C4)").floorLabel == "7F")
        #expect(try place("TR-310-1") != place("TR-310-2"))
    }

    @Test("basements, whole floors, the other campus and a floor written in characters")
    func otherShapes() throws {
        #expect(try place("T4-B1").floorLabel == "B1")
        #expect(try place("EE-B03").floorLabel == "B1")
        #expect(try place("EE-B03").building == "EE")
        #expect(try place("XY-B205").floorLabel == "B2")
        #expect(try place("IB-9F").floorLabel == "9F")
        #expect(try place("HHC-A304").building == "HHC-A")
        #expect(try place("HHC-A304").floorLabel == "3F")
        #expect(try place("華夏體育館2樓桌球室").floorLabel == "2F")
        #expect(try place(" tr-214 ") == place("TR-214"))
    }

    @Test("a placeholder for a room to be set has no place")
    func noPlace() {
        #expect(RoomPlace(room: "系上安排") == nil)
        #expect(RoomPlace(room: "") == nil)
        #expect(RoomPlace(room: "TR-") == nil)
    }
}

struct CampusWalkTests {
    private func seconds(_ from: String, _ to: String) throws -> Double {
        let start = try #require(RoomPlace(room: from))
        let end = try #require(RoomPlace(room: to))
        return try #require(CampusWalk.seconds(from: start, to: end))
    }

    @Test("the same room, then the same floor, then upstairs, then other buildings by distance")
    func ordering() throws {
        let rooms = ["TR-214", "TR-209", "TR-309", "TR-614", "T4-301", "IB-305", "EE-311"]
        let costs = try rooms.map { try seconds("TR-214", $0) }
        #expect(costs == costs.sorted())
        #expect(Set(costs).count == costs.count)
        #expect(costs[0] == 0)
    }

    @Test("stairs up to three floors, the lift beyond")
    func floors() throws {
        #expect(try seconds("TR-214", "TR-509") == 45)
        #expect(try seconds("TR-309", "TR-912") == 63)
        #expect(CampusWalk.floorSeconds(1) == 15)
        #expect(CampusWalk.floorSeconds(4) == 57)
    }

    @Test("between buildings the walk adds a minute and the floors down and up again")
    func buildings() throws {
        let neighbours = try seconds("E2-102", "IB-101")
        let across = try seconds("TR-309", "IB-305")
        #expect(abs(neighbours - 140) < 5)
        #expect(abs(across - 489) < 10)
        #expect(try seconds("IB-305", "TR-309") == across)
    }

    @Test("a building the model has no position for has no walk to another")
    func unknownBuilding() throws {
        let start = try #require(RoomPlace(room: "HHC-A304"))
        let end = try #require(RoomPlace(room: "TR-214"))
        #expect(CampusWalk.seconds(from: start, to: end) == nil)
        #expect(!CampusWalk.hasLocation(start))
        #expect(CampusWalk.hasLocation(end))
    }

    @Test("a walk rounds to whole minutes, at least one")
    func minutes() {
        #expect(CampusWalk.minutes(20) == 1)
        #expect(CampusWalk.minutes(89) == 1)
        #expect(CampusWalk.minutes(91) == 2)
        #expect(CampusWalk.minutes(489) == 8)
    }

    @Test("the badge between two rooms")
    func moves() {
        func move(_ from: String, _ to: String) -> RoomMove? {
            RoomMove.between(RoomPlace(room: from), RoomPlace(room: to))
        }
        #expect(move("TR-309", "TR-309") == .sameRoom)
        #expect(move("TR-214", "TR-309") == .floors(1))
        #expect(move("TR-614", "TR-214") == .floors(-4))
        #expect(move("TR-212", "TR-214") == nil)
        #expect(move("TR-309", "IB-305") == .walk(minutes: 8))
        #expect(move("HHC-A304", "TR-214") == nil)
        #expect(move("系上安排", "TR-214") == nil)
    }
}
