import Foundation

nonisolated enum RoomSlotUse: Equatable, Sendable {
    case free
    case booked
    case course(name: String, teacher: String)
}

nonisolated struct RoomUsage: Equatable, Sendable, Identifiable {
    let room: String
    let slots: [RoomSlotUse]

    var id: String { room }

    func isFree(at period: Int) -> Bool {
        slots.indices.contains(period) && slots[period] == .free
    }

    func freeUntil(from period: Int) -> Int? {
        guard isFree(at: period) else { return nil }
        var last = period
        while isFree(at: last + 1) { last += 1 }
        return last
    }
}

nonisolated struct CampusUsage: Equatable, Sendable {
    let rooms: [RoomUsage]
    let buildingNames: [String: String]
}
