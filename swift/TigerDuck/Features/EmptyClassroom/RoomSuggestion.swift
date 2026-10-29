import Foundation

nonisolated struct ClassStop: Equatable, Sendable {
    let course: String
    let room: String
    let place: RoomPlace?
    let firstPeriod: Int
    let lastPeriod: Int
}

extension ClassStop {
    static func stops(from slots: [CourseTimeSlot], rawRoom: (String) -> String) -> [ClassStop] {
        slots.flatMap { slot -> [ClassStop] in
            let weekday = slot.date.scheduleWeekday
            var runs: [(moved: String?, key: String, positions: [Int])] = []
            for (position, period) in slot.periods.enumerated() {
                let moved = slot.changes.first { $0.kind == .room && $0.covers(period) }?.room
                let key = moved ?? slot.course.classroom(weekday: weekday, period: period)
                if let last = runs.last, last.key == key {
                    runs[runs.count - 1].positions.append(position)
                } else {
                    runs.append((moved, key, [position]))
                }
            }
            let hours = slot.hasChangedTime ? EmptyClassroomSchedule.periods(from: slot.start, to: slot.end) : nil
            return runs.compactMap { run in
                let originals = run.positions.map { slot.periods[$0] }
                // A changed time sets the hours the class holds; its rooms keep their order and
                // share those hours as they shared the timetable periods, each room at least one.
                let periods = hours.map { hours -> [Int] in
                    guard let first = run.positions.first, let last = run.positions.last, !hours.isEmpty else { return [] }
                    let count = slot.periods.count
                    let low = first * hours.count / count
                    return Array(hours[low...max(low, ((last + 1) * hours.count - 1) / count)])
                } ?? originals.compactMap { EmptyClassroomSchedule.periodIDs.firstIndex(of: $0) }
                return stop(
                    slot,
                    shown: run.moved ?? slot.course.classroom(weekday: weekday, periods: originals),
                    periods: periods,
                    rawRoom: rawRoom
                )
            }
        }
    }

    private static func stop(
        _ slot: CourseTimeSlot, shown: String, periods: [Int], rawRoom: (String) -> String
    ) -> ClassStop? {
        guard let first = periods.min(), let last = periods.max() else { return nil }
        let room = CourseBlockRoom.split(shown).first ?? shown
        return ClassStop(
            course: slot.course.displayName,
            room: room,
            place: RoomPlace(room: rawRoom(room)),
            firstPeriod: first,
            lastPeriod: last
        )
    }
}

nonisolated struct RoomSuggestion: Equatable, Sendable {
    struct Candidate: Equatable, Sendable {
        let room: RoomUsage
        let place: RoomPlace?
        let freeUntil: Int
        let fits: Bool
        let seconds: Double
    }

    let period: Int
    let previous: ClassStop?
    let next: ClassStop?
    let candidates: [Candidate]

    static func make(rooms: [RoomUsage], period: Int, classes: [ClassStop], limit: Int = 3) -> RoomSuggestion? {
        if classes.contains(where: { $0.firstPeriod <= period && period <= $0.lastPeriod }) { return nil }
        let previous = classes.filter { $0.lastPeriod < period }.max { $0.lastPeriod < $1.lastPeriod }
        let next = classes.filter { $0.firstPeriod > period }.min { $0.firstPeriod < $1.firstPeriod }
        let origins = [previous, next].compactMap { $0?.place }.filter(CampusWalk.hasLocation)
        guard !origins.isEmpty else { return nil }

        let ranked = rooms.compactMap { room -> Candidate? in
            guard let freeUntil = room.freeUntil(from: period) else { return nil }
            let place = RoomPlace(room: room.room)
            let seconds = place.map { place in
                walk(previous?.place) { CampusWalk.seconds(from: $0, to: place) }
                    + walk(next?.place) { CampusWalk.seconds(from: place, to: $0) }
            } ?? .infinity
            let fits = next.map { freeUntil >= $0.firstPeriod - 1 } ?? false
            return Candidate(room: room, place: place, freeUntil: freeUntil, fits: fits, seconds: seconds)
        }
        .sorted(by: ranksBefore)
        guard !ranked.isEmpty else { return nil }
        return RoomSuggestion(
            period: period, previous: previous, next: next, candidates: Array(ranked.prefix(limit))
        )
    }

    private static func walk(_ stop: RoomPlace?, _ seconds: (RoomPlace) -> Double?) -> Double {
        guard let stop, CampusWalk.hasLocation(stop) else { return 0 }
        return seconds(stop) ?? .infinity
    }

    private static func ranksBefore(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.fits != rhs.fits { return lhs.fits }
        if lhs.seconds != rhs.seconds { return lhs.seconds < rhs.seconds }
        if lhs.freeUntil != rhs.freeUntil { return lhs.freeUntil > rhs.freeUntil }
        return lhs.room.room < rhs.room.room
    }

    func freeSpan(of candidate: Candidate) -> ClosedRange<Int> {
        let end = next.map { min(candidate.freeUntil, $0.firstPeriod - 1) } ?? candidate.freeUntil
        return period...max(period, end)
    }
}
