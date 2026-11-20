import SwiftUI
import TigerDuckCore

enum TimeSliderItem: Identifiable, Equatable, TimedClass {
    case course(CourseTimeSlot)
    /// `day` is the start of the activity's Taipei day.
    case club(ClassTableClubLayout.Segment, day: Date)

    var id: String {
        switch self {
        case .course(let slot): slot.id
        case .club(let piece, _): "club-\(piece.occurrence.id)@\(piece.start)"
        }
    }

    var start: Date {
        switch self {
        case .course(let slot): slot.start
        case .club(let piece, let day): day.addingTimeInterval(TimeInterval(piece.start * 60))
        }
    }

    var end: Date {
        switch self {
        case .course(let slot): slot.end
        case .club(let piece, let day): day.addingTimeInterval(TimeInterval(piece.end * 60))
        }
    }

    var date: Date {
        switch self {
        case .course(let slot): slot.date
        case .club(_, let day): day
        }
    }

    var color: Color {
        switch self {
        case .course(let slot): slot.color
        case .club(let piece, _): Color(hex: UInt(piece.occurrence.color))
        }
    }

    var isCancelled: Bool {
        if case .course(let slot) = self { slot.isCancelled } else { false }
    }

    static func timeline(courses: [CourseTimeSlot], clubs: [ClubOccurrence], days: [Date]) -> [TimeSliderItem] {
        guard !clubs.isEmpty else { return courses.map(TimeSliderItem.course) }
        let starts = Dictionary(days.map { (TaipeiTime.dayKey(for: $0), TaipeiTime.calendar.startOfDay(for: $0)) }) { first, _ in first }
        let classes = Dictionary(grouping: courses) { TaipeiTime.dayKey(for: $0.date) }
        let pieces = Dictionary(grouping: clubs, by: \.day).flatMap { key, activities -> [TimeSliderItem] in
            guard let day = starts[key] else { return [] }
            func minute(_ time: Date) -> Int { Int(time.timeIntervalSince(day) / 60) }
            let blockers = (classes[key] ?? []).map { (start: minute($0.start), end: minute($0.end)) }
            return ClassTableClubLayout.segments(of: activities, courses: blockers).map { .club($0, day: day) }
        }
        return (courses.map(TimeSliderItem.course) + pieces).enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)
    }
}

struct TimeSliderSchedule {
    var courses: [CourseStore.Course] = []
    let isQuietDay: (Date) -> Bool
    let clubs: ClubActivities

    func items(around center: Date) -> [TimeSliderItem] {
        let radius = TimeSliderMetrics.timelineDayRadius
        let slots = CourseTimeSlot.buildMultiDaySlots(from: courses, centerDate: center, dayRadius: radius)
            .filter { !isQuietDay($0.date) && !$0.isSkipped }
        let days = CourseTimeSlot.days(around: center, radius: radius)
        return TimeSliderItem.timeline(courses: slots, clubs: clubs.occurrences(on: days), days: days)
    }

    static func hasClubActivities(from now: Date, in clubs: ClubActivities) -> Bool {
        let today = TaipeiTime.calendar.startOfDay(for: now)
        let days = CourseTimeSlot.days(around: now, radius: TimeSliderMetrics.timelineDayRadius).filter { $0 >= today }
        return !clubs.occurrences(on: days).isEmpty
    }
}
