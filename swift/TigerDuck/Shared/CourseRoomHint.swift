import Foundation

/// The room preview the class table prints in the corner of a course cell.
///
/// A cell is ~50pt wide and already spends its space on the course name, so
/// only a short room *code* can be shown there: the building-and-number
/// forms NTUST's portal reports ("TR-313", "IB-409-1") and the spaced form
/// the classroom-display toggle produces. Everything else the portal calls a
/// classroom is prose — "Heping Cheng 101", "Gongguan Track and Field
/// Ground", "系上自行安排" — and would shrink past legibility or truncate,
/// so no hint is drawn for those. The detail sheet still shows the full room.
enum CourseRoomHint {
    /// `AA-999`, `AA-999-9`, or `AA 9 999`.
    private static let shortRoomCode = try! NSRegularExpression(
        pattern: #"^(\w\w-\w\w\w(-\w)?|\w\w \w \w\w\w)$"#
    )

    /// The hint for one timetable slot, or `nil` when the slot has no room
    /// or its room is not one of the short codes above.
    ///
    /// Callers must not ask for a slot inside a 衝堂 cluster: the cell is
    /// then split between courses and there is no corner left to print in.
    static func room(for course: SDCourse, weekday: Int, periodId: String) -> String? {
        let slotRoom = course.classroom(weekday: weekday, period: periodId)
        let room = slotRoom.isEmpty ? course.classroom(for: weekday) : slotRoom
        return isShortCode(room) ? room : nil
    }

    static func isShortCode(_ room: String) -> Bool {
        let range = NSRange(room.startIndex..., in: room)
        return shortRoomCode.firstMatch(in: room, range: range) != nil
    }
}
