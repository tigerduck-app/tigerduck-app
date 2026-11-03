import SwiftUI
import TigerDuckCore

/// What the time machine draws and its card shows: a class, or the part of a subscribed club's
/// activity that no class and no club ranked above it covers.
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

    /// `courses` in their order, which is by start, and the pieces of `clubs` that the classes of
    /// their day and the clubs ranked above them leave, merged in by start. `days` are the days
    /// `clubs` fall on.
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

/// The courses and the subscribed clubs the time machine draws.
struct TimeSliderSchedule {
    var courses: [CourseStore.Course] = []
    let isQuietDay: (Date) -> Bool
    let clubs: ClubActivities

    /// The classes of the days within `TimeSliderMetrics.timelineDayRadius` of `center`, less those
    /// of a quiet day and the skipped ones, and the clubs' activities of those days, which are dated
    /// events and so show on a quiet day too.
    func items(around center: Date) -> [TimeSliderItem] {
        let radius = TimeSliderMetrics.timelineDayRadius
        let slots = CourseTimeSlot.buildMultiDaySlots(from: courses, centerDate: center, dayRadius: radius)
            .filter { !isQuietDay($0.date) && !$0.isSkipped }
        let days = CourseTimeSlot.days(around: center, radius: radius)
        return TimeSliderItem.timeline(courses: slots, clubs: clubs.occurrences(on: days), days: days)
    }
}
