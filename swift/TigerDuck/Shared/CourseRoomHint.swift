import Foundation

enum CourseRoomHint {
    /// character class because ICU reads `\w` as any Unicode word character, so
    /// hyphenated Chinese prose would match `\w\w-\w\w\w`.
    private static let shortRoomCode = try! NSRegularExpression(
        pattern: #"^([A-Za-z0-9]{2}-[A-Za-z0-9]{3}(-[A-Za-z0-9])?|[A-Za-z0-9]{2} [A-Za-z0-9] [A-Za-z0-9]{3}|\p{Han}{1,3}[A-Za-z]?\d{2,4}(-\d)?)$"#
    )

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
