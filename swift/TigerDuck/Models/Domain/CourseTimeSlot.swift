import Foundation
import SwiftUI
import TigerDuckCore

struct CourseTimeSlot: Identifiable, Equatable, TimedClass {
    static let defaultDayRadius: Int = 28

    static func == (lhs: CourseTimeSlot, rhs: CourseTimeSlot) -> Bool {
        lhs.id == rhs.id
    }

    let id: String
    /// The course's number; the course itself is read from the store or the list the slot came
    /// from, so a slot never holds an edited course's old copy.
    let courseKey: String
    /// The course's name and teacher as the slot was built.
    let title: String
    let instructor: String
    let start: Date
    let end: Date
    let date: Date
    var periods: [String] = []
    /// The school's changes to this class; `start` and `end` already hold a changed time.
    var changes: [CourseChange] = []
    /// The timetable's time, kept only when a change moved it.
    var originalStart: Date?
    var originalEnd: Date?
    /// Whether the user skips the course on `date`.
    let isSkipped: Bool
    private let roomMap: [String: String]
    private let fallbackRoom: String

    init(
        id: String, course: SDCourse, start: Date, end: Date, date: Date, periods: [String] = [],
        changes: [CourseChange] = [], originalStart: Date? = nil, originalEnd: Date? = nil
    ) {
        self.id = id
        courseKey = course.courseNo
        title = course.displayName
        instructor = course.instructor
        self.start = start
        self.end = end
        self.date = date
        self.periods = periods
        self.changes = changes
        self.originalStart = originalStart
        self.originalEnd = originalEnd
        isSkipped = course.isSkipped(on: date)
        roomMap = course.classroomMap
        fallbackRoom = SDCourse.dedup(course.classroom)
    }

    var color: Color { TigerDuckTheme.courseColor(for: courseKey) }
    var isCancelled: Bool { changes.contains { $0.kind == .cancelled } }
    var notes: [CourseChange] { changes.filter { $0.kind == .note } }
    var room: String {
        changes.first { $0.kind == .room }?.room ?? timetableRoom(of: periods)
    }
    var isSkippedOrCancelled: Bool { isCancelled || isSkipped }

    /// The timetable's room of some of its periods.
    func timetableRoom(of periods: [String]) -> String {
        CourseBlockRoom.room(weekday: date.scheduleWeekday, periods: periods, map: roomMap, fallback: fallbackRoom)
    }

    func timetableRoom(period: String) -> String {
        roomMap["\(date.scheduleWeekday)-\(period)"] ?? ""
    }

    func course(in courses: [SDCourse]) -> SDCourse? {
        courses.first { $0.courseNo == courseKey }
    }
    var hasChangedRoom: Bool { changes.contains { $0.kind == .room } }
    var hasChangedTime: Bool { originalStart != nil || originalEnd != nil }

    /// A timetable meeting on one day as the school changed it, its fragments merged back. A
    /// cancellation of some of its periods leaves it standing; a room or note over any applies.
    static func meeting(
        of course: SDCourse, periods: [String], on date: Date, changes: CourseChanges = .cached
    ) -> CourseTimeSlot? {
        CourseMeeting.merged(CourseMeeting.meetings(of: course, on: date, changes: changes).filter { $0.periods.contains(where: periods.contains) })
    }

    static func changedMeetings(of course: SDCourse, on date: Date, changes: CourseChanges = .cached) -> [CourseTimeSlot] {
        CourseMeeting.meetings(of: course, on: date, changes: changes)
            .compactMap { CourseMeeting.merged([$0]) }
            .filter { !$0.changes.isEmpty }
    }

    /// The classes of each meeting the school moved, cancelled or gave a new room on a day, as
    /// the day's slots show them.
    static func changedClasses(of course: SDCourse, on date: Date, changes: CourseChanges = .cached) -> [CourseTimeSlot] {
        CourseMeeting.meetings(of: course, on: date, changes: changes)
            .filter { meeting in meeting.changes.contains { $0.kind != .note } }
            .flatMap { $0.slots() }
    }

    static func upcomingChanges(
        of course: SDCourse, from today: Date, changes: CourseChanges = .cached
    ) -> [(day: Date, meetings: [CourseTimeSlot])] {
        let start = AcademicCalendar.startOfDay(today)
        return changes.days(courseNo: course.courseNo)
            .filter { $0 >= start }
            .map { (day: $0, meetings: changedMeetings(of: course, on: $0, changes: changes)) }
            .filter { !$0.meetings.isEmpty }
    }

    static func buildSlots(
        from courses: [SDCourse],
        weekday: Int,
        on date: Date = AppClock.now(),
        changes: CourseChanges = .cached
    ) -> [CourseTimeSlot] {
        courses
            .flatMap { course in
                CourseMeeting.meetings(of: course, weekday: weekday, on: date, changes: changes).flatMap { $0.slots() }
            }
            .sorted { $0.start < $1.start }
    }

    static func meetingSlots(
        from courses: [SDCourse],
        on date: Date,
        isClassDay: (Date) -> Bool,
        changes: CourseChanges = .cached
    ) -> [CourseTimeSlot] {
        guard isClassDay(date) else { return [] }
        return buildSlots(from: courses, weekday: date.scheduleWeekday, on: date, changes: changes)
            .filter { !$0.isSkippedOrCancelled }
    }

    static func isSkipped(slotId id: String, in courses: [SDCourse], changes: CourseChanges = .cached) -> Bool {
        let parts = id.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count >= 3, let day = dayKeyFormatter.date(from: String(parts[parts.count - 2])) else {
            return false
        }
        let courseNo = parts.dropLast(2).joined(separator: "_")
        return courses.contains { $0.courseNo == courseNo && $0.isSkipped(on: day) }
            || changes.isCancelled(courseNo: courseNo, on: day, period: String(parts[parts.count - 1]))
    }

    /// Whether the class `id` names is over at `now` by its changed times: its own piece when one
    /// still has that id, or else every piece of its meeting that is not cancelled, as a change can
    /// drop the piece an activity began with.
    static func hasEnded(slotId id: String, in courses: [SDCourse], at now: Date, changes: CourseChanges = .cached) -> Bool {
        let parts = id.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count >= 3, let day = dayKeyFormatter.date(from: String(parts[parts.count - 2])) else {
            return false
        }
        let courseNo = parts.dropLast(2).joined(separator: "_")
        let period = String(parts[parts.count - 1])
        return courses.filter { $0.courseNo == courseNo }.contains { course in
            guard let meeting = CourseMeeting.meetings(of: course, on: day, changes: changes).first(where: { $0.periods.contains(period) })
            else { return false }
            let pieces = meeting.fragments()
            let running = (pieces.isEmpty ? [CourseMeeting.merged([meeting])].compactMap { $0 } : pieces).filter { !$0.isCancelled }
            if let own = running.first(where: { $0.id == id }) { return own.end <= now }
            return running.allSatisfy { $0.end <= now }
        }
    }

    static func buildMultiDaySlots(
        from courses: [SDCourse],
        centerDate: Date,
        dayRadius: Int = CourseTimeSlot.defaultDayRadius,
        changes: CourseChanges = .cached
    ) -> [CourseTimeSlot] {
        let calendar = TaipeiTime.calendar
        var allSlots: [CourseTimeSlot] = []

        for offset in -dayRadius...dayRadius {
            guard let date = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: centerDate)) else { continue }
            let weekday = date.scheduleWeekday
            let daySlots = buildSlots(from: courses, weekday: weekday, on: date, changes: changes)
            allSlots.append(contentsOf: daySlots)
        }

        return allSlots.sorted { $0.start < $1.start }
    }

    static func dateFromTimeString(_ time: String, on date: Date, calendar: Calendar = TaipeiTime.calendar) -> Date? {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        var dc = calendar.dateComponents([.year, .month, .day], from: date)
        dc.hour = parts[0]
        dc.minute = parts[1]
        dc.second = 0
        return calendar.date(from: dc)
    }

    static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TaipeiTime.timeZone
        f.dateFormat = "yyyyMMdd"
        return f
    }()
}
