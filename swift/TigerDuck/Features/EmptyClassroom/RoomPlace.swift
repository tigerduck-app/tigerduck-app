import Foundation

nonisolated struct RoomPlace: Equatable, Sendable {
    let room: String
    let building: String
    let level: Int
    let number: Int?

    /// Reads `TR-214`, `TR-310-1`, `IB-1006`, `IB-9F`, `EE-B03`, `T4-B1` and `HHC-A304`, where
    /// the hundreds give the floor and 0 means B1, and a name that writes its floor in
    /// characters. Nil for a name with no floor, such as a placeholder for a room to be set.
    init?(room name: String) {
        let room = name.uppercased().filter { !$0.isWhitespace }
        if let match = room.wholeMatch(of: /HHC-([A-Z])(\d{3,4}).*/), let number = Int(match.2) {
            self.init(room: room, building: "HHC-\(match.1)", level: number / 100, number: number)
        } else if let match = room.wholeMatch(of: /([A-Z]{1,3}\d?)-(.+)/) {
            guard let floor = Self.floor(of: String(match.2)) else { return nil }
            self.init(room: room, building: String(match.1), level: floor.level, number: floor.number)
        } else if let match = room.firstMatch(of: /(\d+)樓/), let level = Int(match.1) {
            self.init(room: room, building: String(room[..<match.range.lowerBound]), level: level, number: nil)
        } else {
            return nil
        }
    }

    private init(room: String, building: String, level: Int, number: Int?) {
        self.room = room
        self.building = building
        self.level = level
        self.number = number
    }

    var floorLabel: String {
        Self.floorLabel(level: level)
    }

    static func floorLabel(level: Int) -> String {
        level >= 1 ? "\(level)F" : "B\(1 - level)"
    }

    /// The part after the building code. A basement written `B03` is room 03 of B1; anything
    /// after the digits, such as `-1` or `A`, names part of a room on the same floor.
    private static func floor(of rest: String) -> (level: Int, number: Int?)? {
        if let match = rest.wholeMatch(of: /B(\d)/), let depth = Int(match.1) {
            return (1 - depth, nil)
        }
        if let match = rest.wholeMatch(of: /B(\d)(\d{2}).*/), let depth = Int(match.1) {
            return (1 - depth, Int(match.2))
        }
        if let match = rest.wholeMatch(of: /B(\d{2}).*/) {
            return (0, Int(match.1))
        }
        if let match = rest.wholeMatch(of: /(\d+)F/), let level = Int(match.1) {
            return (level, nil)
        }
        if let match = rest.wholeMatch(of: /(\d{3,4}).*/), let number = Int(match.1) {
            return (number / 100, number)
        }
        return nil
    }
}

nonisolated enum CampusWalk {
    static func seconds(from start: RoomPlace, to end: RoomPlace) -> Double? {
        if start.room == end.room { return 0 }
        if start.building == end.building {
            let floors = abs(start.level - end.level)
            if floors > 0 { return floorSeconds(floors) }
            let apart = abs((start.number ?? 0) - (end.number ?? 0))
            return 1 + Double(min(apart, 9))
        }
        guard let from = buildings[start.building], let to = buildings[end.building] else { return nil }
        return 1.3 * metres(from, to) / 1.2 + 60
            + floorSeconds(abs(start.level - 1)) + floorSeconds(abs(end.level - 1))
    }

    static func floorSeconds(_ floors: Int) -> Double {
        Double(min(15 * floors, 45 + 3 * floors))
    }

    static func minutes(_ seconds: Double) -> Int {
        max(1, Int((seconds / 60).rounded()))
    }

    static func hasLocation(_ place: RoomPlace) -> Bool {
        buildings[place.building] != nil
    }

    static func metres(from building: String, to other: String) -> Double? {
        guard let from = buildings[building], let to = buildings[other] else { return nil }
        return metres(from, to)
    }

    private static let buildings: [String: (latitude: Double, longitude: Double)] = [
        "AD": (25.01323, 121.54108),
        "AU": (25.01404, 121.54165),
        "E1": (25.01336, 121.54214),
        "E2": (25.01253, 121.54072),
        "EE": (25.01189, 121.54137),
        "IA": (25.01461, 121.54319),
        "IB": (25.01304, 121.54025),
        "LB": (25.01382, 121.54121),
        "MA": (25.01239, 121.54126),
        "RB": (25.01423, 121.54140),
        "T1": (25.01435, 121.54178),
        "T2": (25.01208, 121.54090),
        "T3": (25.01350, 121.54291),
        "T4": (25.01388, 121.54177),
        "TR": (25.01505, 121.54280),
    ]

    private static func metres(
        _ from: (latitude: Double, longitude: Double),
        _ to: (latitude: Double, longitude: Double)
    ) -> Double {
        let metresPerDegree = 111_320.0
        let latitude = (from.latitude + to.latitude) / 2 * .pi / 180
        let east = (to.longitude - from.longitude) * metresPerDegree * cos(latitude)
        let north = (to.latitude - from.latitude) * metresPerDegree
        return (east * east + north * north).squareRoot()
    }
}

nonisolated enum RoomMove: Equatable, Sendable {
    case sameRoom
    case floors(Int)
    case walk(minutes: Int)

    static func between(_ start: RoomPlace?, _ end: RoomPlace?) -> RoomMove? {
        guard let start, let end else { return nil }
        if start.room == end.room { return .sameRoom }
        if start.building == end.building {
            let floors = end.level - start.level
            return floors == 0 ? nil : .floors(floors)
        }
        return CampusWalk.seconds(from: start, to: end).map { .walk(minutes: CampusWalk.minutes($0)) }
    }
}
