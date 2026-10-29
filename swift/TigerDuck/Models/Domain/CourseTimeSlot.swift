import Foundation

struct CourseTimeSlot: Identifiable, Equatable {
    static let defaultDayRadius: Int = 28

    static func == (lhs: CourseTimeSlot, rhs: CourseTimeSlot) -> Bool {
        lhs.id == rhs.id
    }

    let id: String
    let course: SDCourse
    let start: Date
    let end: Date
    let date: Date
    var periods: [String] = []
    /// The school's changes to this class; `start` and `end` already hold a changed time.
    var changes: [CourseChange] = []
    /// The timetable's time, kept only when a change moved it.
    var originalStart: Date?
    var originalEnd: Date?

    var isCancelled: Bool { changes.contains { $0.kind == .cancelled } }
    var notes: [CourseChange] { changes.filter { $0.kind == .note } }
    var room: String {
        changes.first { $0.kind == .room }?.room
            ?? course.classroom(weekday: date.scheduleWeekday, periods: periods)
    }
    var isSkippedOrCancelled: Bool { isCancelled || course.isSkipped(on: date) }
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
        let periods = (course.schedule[weekday ?? date.scheduleWeekday] ?? []).sortedByPeriodOrder()
        var runs: [[String]] = []
        for period in periods {
            if let last = runs.last?.last, periodOrder(period) - 1 == periodOrder(last) {
                runs[runs.count - 1].append(period)
            } else {
                runs.append([period])
            }
        }
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

    private static func periodOrder(_ periodId: String) -> Int {
        AppConstants.Periods.chronologicalOrder.firstIndex(of: periodId) ?? Int.max
    }

    static func buildMultiDaySlots(
        from courses: [SDCourse],
        centerDate: Date,
        dayRadius: Int = CourseTimeSlot.defaultDayRadius,
        changes: CourseChanges = .cached
    ) -> [CourseTimeSlot] {
        let calendar = AppConstants.taipeiCalendar
        var allSlots: [CourseTimeSlot] = []

        for offset in -dayRadius...dayRadius {
            guard let date = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: centerDate)) else { continue }
            let weekday = date.scheduleWeekday
            let daySlots = buildSlots(from: courses, weekday: weekday, on: date, changes: changes)
            allSlots.append(contentsOf: daySlots)
        }

        return allSlots.sorted { $0.start < $1.start }
    }

    static func dateFromTimeString(_ time: String, on date: Date, calendar: Calendar = AppConstants.taipeiCalendar) -> Date? {
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
        f.timeZone = AppConstants.taipeiTimeZone
        f.dateFormat = "yyyyMMdd"
        return f
    }()
}
