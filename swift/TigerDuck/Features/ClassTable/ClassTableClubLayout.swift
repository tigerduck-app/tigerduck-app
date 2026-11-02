import CoreGraphics
import Foundation

/// Where the class table draws the club activities of a day. Clubs never share a column: an
/// activity shows only where no course and no club ranked above it takes the time, so it may be
/// cut into pieces or hidden.
nonisolated enum ClassTableClubLayout {
    typealias Interval = (start: Int, end: Int)

    static let nameHeight: CGFloat = 24
    static let locationHeight: CGFloat = 44

    /// A piece of an activity, in minutes after midnight.
    struct Segment: Equatable {
        let occurrence: ClubOccurrence
        let start: Int
        let end: Int
        /// A course or a higher-ranked activity ends where the piece starts.
        let startsAtBlocker: Bool
        /// A course or a higher-ranked activity starts where the piece ends.
        let endsAtBlocker: Bool
    }

    struct Block: Equatable, Identifiable {
        let segment: Segment
        let top: CGFloat
        let height: CGFloat

        var id: String { "\(segment.occurrence.id)@\(segment.start)" }
        var showsName: Bool { height >= ClassTableClubLayout.nameHeight }
        var showsLocation: Bool { height >= ClassTableClubLayout.locationHeight }
    }

    /// Each activity of `day` less `courses` and every activity ranked above it.
    static func segments(of day: [ClubOccurrence], courses: [Interval]) -> [Segment] {
        var blockers = courses
        var segments: [Segment] = []
        for occurrence in ranked(day) {
            segments += pieces(of: (occurrence.start, occurrence.end), less: blockers).map { piece in
                Segment(
                    occurrence: occurrence, start: piece.start, end: piece.end,
                    startsAtBlocker: blockers.contains { $0.end == piece.start },
                    endsAtBlocker: blockers.contains { $0.start == piece.end }
                )
            }
            blockers.append((occurrence.start, occurrence.end))
        }
        return segments
    }

    /// The pieces with room to draw, placed on rows of `periods` as the now line is. A piece leaves
    /// the grid's gap between rows where it meets a course or a higher-ranked activity.
    static func blocks(
        _ segments: [Segment], periods: [Interval], rowPitch: CGFloat, cellHeight: CGFloat
    ) -> [Block] {
        let gap = rowPitch - cellHeight
        func y(_ minute: Int) -> CGFloat {
            TimetableNowLine.position(minute: minute, periods: periods, rowPitch: rowPitch, cellHeight: cellHeight)
        }
        return segments.compactMap { segment in
            let top = y(segment.start) + (segment.startsAtBlocker ? gap : 0)
            let bottom = y(segment.end) - (segment.endsAtBlocker ? gap : 0)
            return bottom > top ? Block(segment: segment, top: top, height: bottom - top) : nil
        }
    }

    /// The minutes the courses of `weekday` take, one interval per period.
    @MainActor static func courseTimes(_ courses: [CourseStore.Course], weekday: Int) -> [Interval] {
        courses.flatMap { $0.schedule[weekday] ?? [] }.compactMap { TimetablePeriod.byId[$0]?.minutes }
    }

    /// The drawn activities whose time meets that of `occurrence`, itself included, highest ranked
    /// first.
    static func overlapping(_ occurrence: ClubOccurrence, among drawn: [ClubOccurrence]) -> [ClubOccurrence] {
        var seen = Set<Int>()
        return ranked(drawn.filter { $0.start < occurrence.end && occurrence.start < $0.end && seen.insert($0.id).inserted })
    }

    private static func ranked(_ occurrences: [ClubOccurrence]) -> [ClubOccurrence] {
        occurrences.sorted { ($0.priority, $0.start, $0.id) < ($1.priority, $1.start, $1.id) }
    }

    private static func pieces(of interval: Interval, less blockers: [Interval]) -> [Interval] {
        blockers.reduce([interval]) { pieces, blocker in
            pieces.flatMap { piece -> [Interval] in
                guard blocker.start < piece.end, piece.start < blocker.end else { return [piece] }
                return [(piece.start, blocker.start), (blocker.end, piece.end)].filter { $0.start < $0.end }
            }
        }
    }
}
