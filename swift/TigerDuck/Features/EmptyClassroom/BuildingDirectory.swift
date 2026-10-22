import Foundation

nonisolated struct BuildingDirectory: Equatable, Sendable {
    struct Building: Equatable, Sendable, Identifiable {
        let code: String
        let free: [RoomUsage]

        var id: String { code }
    }

    struct Floor: Equatable, Sendable, Identifiable {
        let level: Int
        let rooms: [RoomUsage]

        var id: Int { level }
        var label: String { RoomPlace.floorLabel(level: level) }
    }

    let buildings: [Building]

    init(rooms: [RoomUsage], period: Int) {
        let byBuilding = Dictionary(grouping: rooms) { RoomPlace(room: $0.room)?.building ?? $0.room }
        buildings = byBuilding.keys.sorted().map { code in
            Building(code: code, free: byBuilding[code, default: []].filter { $0.isFree(at: period) })
        }
    }

    func floors(of code: String) -> [Floor] {
        guard let building = buildings.first(where: { $0.code == code }) else { return [] }
        let placed = building.free.map { (room: $0, place: RoomPlace(room: $0.room)) }
        let byLevel = Dictionary(grouping: placed) { $0.place?.level ?? 1 }
        return byLevel.keys.sorted().map { level in
            let rooms = byLevel[level, default: []].sorted { lhs, rhs in
                let left = lhs.place?.number ?? 0
                let right = rhs.place?.number ?? 0
                return left != right ? left < right : lhs.room.room < rhs.room.room
            }
            return Floor(level: level, rooms: rooms.map(\.room))
        }
    }

    func nearby(_ code: String, limit: Int = 2) -> [Building] {
        let distance = { (other: Building) in CampusWalk.metres(from: code, to: other.code) ?? .infinity }
        let candidates = buildings.filter { $0.code != code && !$0.free.isEmpty }
        return Array(candidates.sorted { lhs, rhs in
            let left = distance(lhs)
            let right = distance(rhs)
            return left != right ? left < right : lhs.code < rhs.code
        }.prefix(limit))
    }

    func defaultBuilding(picked: String?, suggested: String?) -> String? {
        let codes = Set(buildings.map(\.code))
        if let picked, codes.contains(picked) { return picked }
        if let suggested, codes.contains(suggested) { return suggested }
        return buildings.sorted { lhs, rhs in
            lhs.free.count != rhs.free.count ? lhs.free.count > rhs.free.count : lhs.code < rhs.code
        }.first?.code
    }
}

nonisolated enum CampusBuildingName {
    static func of(_ code: String) -> String? {
        switch code {
        case "AD": String(localized: "empty_classroom_building_ad")
        case "AU": String(localized: "empty_classroom_building_au")
        case "E1": String(localized: "empty_classroom_building_e1")
        case "E2": String(localized: "empty_classroom_building_e2")
        case "EE": String(localized: "empty_classroom_building_ee")
        case "IA": String(localized: "empty_classroom_building_ia")
        case "IB": String(localized: "empty_classroom_building_ib")
        case "LB": String(localized: "empty_classroom_building_lb")
        case "MA": String(localized: "empty_classroom_building_ma")
        case "RB": String(localized: "empty_classroom_building_rb")
        case "T1": String(localized: "empty_classroom_building_t1")
        case "T2": String(localized: "empty_classroom_building_t2")
        case "T3": String(localized: "empty_classroom_building_t3")
        case "T4": String(localized: "empty_classroom_building_t4")
        case "TR": String(localized: "empty_classroom_building_tr")
        default: nil
        }
    }
}
