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
        merged(meetings(of: course, on: date, changes: changes).filter { $0.periods.contains(where: periods.contains) })
    }

    static func changedMeetings(of course: SDCourse, on date: Date, changes: CourseChanges = .cached) -> [CourseTimeSlot] {
        meetings(of: course, on: date, changes: changes)
            .compactMap { merged([$0]) }
            .filter { !$0.changes.isEmpty }
    }

    /// The classes of each meeting the school moved, cancelled or gave a new room on a day, as
    /// the day's slots show them.
    static func changedClasses(of course: SDCourse, on date: Date, changes: CourseChanges = .cached) -> [CourseTimeSlot] {
        meetings(of: course, on: date, changes: changes)
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
                meetings(of: course, weekday: weekday, on: date, changes: changes).flatMap { $0.slots() }
            }
            .sorted { $0.start < $1.start }
    }

    /// One run of consecutive timetable periods on a day. A new start or end moves the run as a
    /// whole; a cancellation or a room covers only its own periods.
    private struct Meeting {
        let course: SDCourse
        let date: Date
        let dayKey: String
        let periods: [String]
        let start: Date
        let end: Date
        let timetableStart: Date
        let timetableEnd: Date
        let changes: [CourseChange]

        func isCancelled(_ period: String) -> Bool {
            changes.contains { $0.kind == .cancelled && $0.covers(period) }
        }

        func room(_ period: String) -> String? {
            changes.first { $0.kind == .room && $0.covers(period) }?.room
        }

        /// Its fragments, or the meeting whole when its new times leave none.
        func slots() -> [CourseTimeSlot] {
            let fragments = fragments()
            return fragments.isEmpty ? [CourseTimeSlot.merged([self])].compactMap { $0 } : fragments
        }

        /// Runs of periods alike in cancellation and room. Inner boundaries keep the timetable
        /// times, clamped into the meeting; a run left empty is dropped, and the outer surviving
        /// ones meet the meeting's own start and end.
        func fragments() -> [CourseTimeSlot] {
            var runs: [[String]] = []
            for period in periods {
                if let last = runs.last?.last, isCancelled(last) == isCancelled(period), room(last) == room(period) {
                    runs[runs.count - 1].append(period)
                } else {
                    runs.append([period])
                }
            }
            let pieces = runs.enumerated().compactMap { index, run -> (run: [String], start: Date, end: Date, ownStart: Date, ownEnd: Date)? in
                guard let ownStart = CourseTimeSlot.periodTime(run[0], end: false, on: date),
                      let ownEnd = CourseTimeSlot.periodTime(run[run.count - 1], end: true, on: date) else { return nil }
                let pieceStart = index == 0 ? start : min(max(ownStart, start), end)
                let pieceEnd = index == runs.count - 1 ? end : min(max(ownEnd, start), end)
                return pieceStart < pieceEnd ? (run, pieceStart, pieceEnd, ownStart, ownEnd) : nil
            }
            return pieces.enumerated().map { index, piece in
                let fragmentStart = index == 0 ? start : piece.start
                let fragmentEnd = index == pieces.count - 1 ? end : piece.end
                return CourseTimeSlot(
                    id: "\(course.courseNo)_\(dayKey)_\(piece.run[0])",
                    course: course,
                    start: fragmentStart,
                    end: fragmentEnd,
                    date: date,
                    periods: piece.run,
                    changes: changes.filter { $0.kind == .start || $0.kind == .end || piece.run.contains(where: $0.covers) },
                    originalStart: fragmentStart == piece.ownStart ? nil : piece.ownStart,
                    originalEnd: fragmentEnd == piece.ownEnd ? nil : piece.ownEnd
                )
            }
        }
    }

    private static func meetings(
        of course: SDCourse, weekday: Int? = nil, on date: Date, changes: CourseChanges
    ) -> [Meeting] {
        let runs = ClassTimeline.runs(
            of: course.schedule[weekday ?? date.scheduleWeekday] ?? [], order: AppConstants.Periods.chronologicalOrder
        )
        let dayChanges = changes.changes(courseNo: course.courseNo, on: date)
        let dayKey = dayKeyFormatter.string(from: date)
        return runs.compactMap { run in
            guard let timetableStart = periodTime(run[0], end: false, on: date),
                  let timetableEnd = periodTime(run[run.count - 1], end: true, on: date) else { return nil }
            var applied = dayChanges.filter { run.contains(where: $0.covers) }
            var start = changedTime(.start, in: applied, on: date) ?? timetableStart
            var end = changedTime(.end, in: applied, on: date) ?? timetableEnd
            // A new start past the end, or a new end before the start, is a feed error; the
            // meeting keeps its times and its other changes.
            if end <= start {
                start = timetableStart
                end = timetableEnd
                applied.removeAll { $0.kind == .start || $0.kind == .end }
            }
            return Meeting(
                course: course, date: date, dayKey: dayKey, periods: run, start: start, end: end,
                timetableStart: timetableStart, timetableEnd: timetableEnd, changes: applied
            )
        }
    }

    /// The meetings as one slot: their own start and end, and cancelled only when every period is.
    private static func merged(_ meetings: [Meeting]) -> CourseTimeSlot? {
        guard let first = meetings.first, let last = meetings.last else { return nil }
        let isCancelled = meetings.allSatisfy { meeting in meeting.periods.allSatisfy(meeting.isCancelled) }
        var merged: [CourseChange] = []
        for change in meetings.flatMap(\.changes)
        where (isCancelled || change.kind != .cancelled) && !merged.contains(where: { $0.id == change.id }) {
            merged.append(change)
        }
        return CourseTimeSlot(
            id: "\(first.course.courseNo)_\(first.dayKey)_\(first.periods[0])",
            course: first.course,
            start: first.start,
            end: last.end,
            date: first.date,
            periods: meetings.flatMap(\.periods),
            changes: merged,
            originalStart: first.start == first.timetableStart ? nil : first.timetableStart,
            originalEnd: last.end == last.timetableEnd ? nil : last.timetableEnd
        )
    }

    private static func periodTime(_ period: String, end: Bool, on date: Date) -> Date? {
        guard let times = AppConstants.PeriodTimes.mapping[period] else { return nil }
        return dateFromTimeString(end ? times.end : times.start, on: date)
    }

    private static func changedTime(_ kind: CourseChange.Kind, in changes: [CourseChange], on date: Date) -> Date? {
        guard let change = changes.first(where: { $0.kind == kind }),
              let time = kind == .start ? change.start : change.end
        else { return nil }
        return dateFromTimeString(time, on: date)
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
            guard let meeting = meetings(of: course, on: day, changes: changes).first(where: { $0.periods.contains(period) })
            else { return false }
            let pieces = meeting.fragments()
            let running = (pieces.isEmpty ? [merged([meeting])].compactMap { $0 } : pieces).filter { !$0.isCancelled }
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

    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TaipeiTime.timeZone
        f.dateFormat = "yyyyMMdd"
        return f
    }()
}
