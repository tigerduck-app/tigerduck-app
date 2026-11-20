import Foundation
import TigerDuckCore

/// The demo week of the room booking site: each room's periods by weekday, `.` free, `b` booked
/// and a digit the class at that place in `classes`, counted from 1. A room's `*` stands for every
/// weekday it does not list, and weekends have no rooms, as on the site.
nonisolated struct DemoClassrooms: Decodable, Sendable {
    struct Class: Decodable, Sendable {
        let name: DemoText
        let teacher: DemoText
    }

    let buildings: [String: String]?
    let classes: [Class]?
    let rooms: [String: [String: String]]?

    static func usage(on day: Date) -> CampusUsage {
        DemoFixture.bundled?.emptyClassroom?.usage(on: day, in: .shown) ?? CampusUsage(rooms: [], buildingNames: [:])
    }

    func usage(on day: Date, in language: DemoLanguage, calendar: Calendar = TaipeiTime.calendar) -> CampusUsage {
        let names = buildings ?? [:]
        let sundayFirst = calendar.component(.weekday, from: day)
        guard (2...6).contains(sundayFirst) else { return CampusUsage(rooms: [], buildingNames: names) }
        let weekday = String(sundayFirst - 1)
        let rooms = (rooms ?? [:]).compactMap { room, week -> RoomUsage? in
            guard let pattern = week[weekday] ?? week["*"] else { return nil }
            let marks = Array(pattern)
            let slots = (0..<ClassroomUsageParser.periodCount).map { period in
                slot(marks.indices.contains(period) ? marks[period] : ".", in: language)
            }
            return RoomUsage(room: room, slots: slots)
        }
        return CampusUsage(rooms: rooms.sorted { $0.room < $1.room }, buildingNames: names)
    }

    private func slot(_ mark: Character, in language: DemoLanguage) -> RoomSlotUse {
        if mark == "b" { return .booked }
        guard let number = mark.wholeNumberValue, let classes, classes.indices.contains(number - 1) else { return .free }
        let taught = classes[number - 1]
        return .course(name: taught.name.text(in: language), teacher: taught.teacher.text(in: language))
    }
}
