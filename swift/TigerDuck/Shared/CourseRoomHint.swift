import Foundation

/// The room preview the class table prints in the corner of a course cell.
///
/// A cell is ~50pt wide and already spends its space on the course name, so
/// only a short room *code* can be shown there: the building-and-number
/// forms NTUST's portal reports ("TR-313", "IB-409-1"), the spaced form the
/// classroom-display toggle produces, and the Chinese building-and-number
/// form the co-listed NTU / NTNU rooms use ("共101", "人文B106"). Everything
/// else the portal calls a classroom is prose — "Heping Cheng 101",
/// "Gongguan Track and Field Ground", "綜合大講堂", "系上自行安排" — and
/// would shrink past legibility or truncate, so no hint is drawn for those.
/// The detail sheet still shows the full room.
enum CourseRoomHint {
    /// `AA-999`, `AA-999-9`, `AA 9 999`, or a Chinese building name followed
    /// by a room number (`共101`, `博雅205`, `人文B106`, `農化二B10-1`).
    ///
    /// The Chinese branch insists on trailing digits, which is what keeps
    /// the placeholders and facility names out: "系上自行安排" and "林一"
    /// are rooms in the same field but nothing a student can walk to by
    /// reading four characters off a grid cell.
    ///
    /// The Latin branches spell the character class out instead of using
    /// `\w`, which ICU reads as *any* Unicode word character — "體育-游泳池"
    /// and "綜合-大講堂" both matched `\w\w-\w\w\w`, which is the prose
    /// this type exists to reject.
    private static let shortRoomCode = try! NSRegularExpression(
        pattern: #"^([A-Za-z0-9]{2}-[A-Za-z0-9]{3}(-[A-Za-z0-9])?|[A-Za-z0-9]{2} [A-Za-z0-9] [A-Za-z0-9]{3}|\p{Han}{1,3}[A-Za-z]?\d{2,4}(-\d)?)$"#
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
