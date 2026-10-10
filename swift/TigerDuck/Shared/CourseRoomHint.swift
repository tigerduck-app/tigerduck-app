import Foundation

/// The room preview the class table prints in the corner of a course cell.
///
/// A cell is ~50pt wide and the course name uses most of it, so only a short room
/// code fits: NTUST's building-and-number forms ("TR-313", "IB-409-1"), the
/// spaced form the classroom-display toggle produces, and the Chinese
/// building-and-number form of co-listed NTU and NTNU rooms. Other values are
/// prose ("Heping Cheng 101", facility names) that would shrink past legibility
/// or truncate, so they get no hint. The detail sheet still shows the full room.
enum CourseRoomHint {
    /// `AA-999`, `AA-999-9`, `AA 9 999`, or a Chinese building name followed by
    /// a room number; see `CourseRoomHintTests` for examples.
    ///
    /// The Chinese branch requires trailing digits, which keeps out placeholders
    /// and facility names: they share the field but name nothing a student can
    /// find from four characters in a grid cell. The Latin branches spell out the
    /// character class because ICU reads `\w` as any Unicode word character, so
    /// hyphenated Chinese prose would match `\w\w-\w\w\w`.
    private static let shortRoomCode = try! NSRegularExpression(
        pattern: #"^([A-Za-z0-9]{2}-[A-Za-z0-9]{3}(-[A-Za-z0-9])?|[A-Za-z0-9]{2} [A-Za-z0-9] [A-Za-z0-9]{3}|\p{Han}{1,3}[A-Za-z]?\d{2,4}(-\d)?)$"#
    )

    /// The hint for one timetable slot, or `nil` when the slot has no room
    /// or its room is not one of the short codes above.
    ///
    /// The whole-day room is only a fallback for a course with no per-slot map.
    /// With a map, a missing slot is one whose room the portal did not give, and
    /// falling back would label it with the other block's room, worse than nothing.
    /// Callers must not ask for a slot in a conflict cluster (overlapping courses):
    /// the cell is split between courses and has no corner left to print in.
    static func room(for course: SDCourse, weekday: Int, periodId: String) -> String? {
        let room = course.classroomMap.isEmpty
            ? course.classroom(for: weekday)
            : course.classroom(weekday: weekday, period: periodId)
        return isShortCode(room) ? room : nil
    }

    static func isShortCode(_ room: String) -> Bool {
        let range = NSRange(room.startIndex..., in: room)
        return shortRoomCode.firstMatch(in: room, range: range) != nil
    }
}
