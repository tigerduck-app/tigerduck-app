import Foundation

/// One of the user's classes on the day in question, by period index (0 is period 1, 13 is D).
nonisolated struct ClassStop: Equatable, Sendable {
    let course: String
    /// The room as the class table shows it.
    let room: String
    let place: RoomPlace?
    let firstPeriod: Int
    let lastPeriod: Int
}

extension ClassStop {
    /// One stop per block of the user's periods. `rawRoom` gives the school's name for a room
    /// the class table shows in another form, which is what the floor rule and the site read.
    static func stops(from slots: [CourseTimeSlot], rawRoom: (String) -> String) -> [ClassStop] {
        slots.compactMap { slot in
            let periods = slot.periods.compactMap { EmptyClassroomSchedule.periodIDs.firstIndex(of: $0) }
            guard let first = periods.min(), let last = periods.max() else { return nil }
            let shown = slot.course.classroom(weekday: slot.date.scheduleWeekday, periods: slot.periods)
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
}

/// The rooms to sit in between the user's classes: free at the chosen period, close to the
/// class before and the class after, and best of all free until the next class starts.
nonisolated struct RoomSuggestion: Equatable, Sendable {
    struct Candidate: Equatable, Sendable {
        let room: RoomUsage
        let place: RoomPlace?
        /// The last period of the room's free run from the chosen period.
        let freeUntil: Int
        let fits: Bool
        let seconds: Double
    }

    let period: Int
    let previous: ClassStop?
    let next: ClassStop?
    /// Best first.
    let candidates: [Candidate]

    /// Nil while the user is in class at `period`, with no class that day before or after it,
    /// when neither class has a room the walking model knows, or when no room is free.
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
                let before = previous?.place.flatMap { CampusWalk.seconds(from: $0, to: place) } ?? 0
                let after = next?.place.flatMap { CampusWalk.seconds(from: place, to: $0) } ?? 0
                return before + after
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

    private static func ranksBefore(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.fits != rhs.fits { return lhs.fits }
        if lhs.seconds != rhs.seconds { return lhs.seconds < rhs.seconds }
        if lhs.freeUntil != rhs.freeUntil { return lhs.freeUntil > rhs.freeUntil }
        return lhs.room.room < rhs.room.room
    }

    /// The periods the card shows the room free for, ending before the next class.
    func freeSpan(of candidate: Candidate) -> ClosedRange<Int> {
        let end = next.map { min(candidate.freeUntil, $0.firstPeriod - 1) } ?? candidate.freeUntil
        return period...max(period, end)
    }
}
