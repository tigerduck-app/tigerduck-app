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

    /// A timetable meeting on one day as the school changed it. A cancellation of some of its
    /// periods leaves it standing; a room, time or note over any of them applies.
    static func meeting(
        of course: SDCourse, periods: [String], on date: Date, changes: CourseChanges = .cached
    ) -> CourseTimeSlot? {
        let parts = buildSlots(from: [course], weekday: date.scheduleWeekday, on: date, changes: changes)
            .filter { $0.periods.contains(where: periods.contains) }
            .sorted { periodOrder($0.periods.first ?? "") < periodOrder($1.periods.first ?? "") }
        guard let first = parts.first, let last = parts.last,
              let start = parts.map(\.start).min(), let end = parts.map(\.end).max() else { return nil }
        let timetableStart = first.originalStart ?? first.start
        let timetableEnd = last.originalEnd ?? last.end
        let isCancelled = parts.allSatisfy(\.isCancelled)
        var merged: [CourseChange] = []
        for change in parts.flatMap(\.changes)
        where (isCancelled || change.kind != .cancelled) && !merged.contains(where: { $0.id == change.id }) {
            merged.append(change)
        }
        return CourseTimeSlot(
            id: first.id, course: course, start: start, end: end, date: date,
            periods: parts.flatMap(\.periods), changes: merged,
            originalStart: start == timetableStart ? nil : timetableStart,
            originalEnd: end == timetableEnd ? nil : timetableEnd
        )
    }

    static func changedMeetings(of course: SDCourse, on date: Date, changes: CourseChanges = .cached) -> [CourseTimeSlot] {
        let weekday = date.scheduleWeekday
        var left = (course.schedule[weekday] ?? []).sortedByPeriodOrder()
        var meetings: [CourseTimeSlot] = []
        while let period = left.first, let block = course.block(weekday: weekday, at: period) {
            left.removeAll(where: block.contains)
            if let meeting = meeting(of: course, periods: block, on: date, changes: changes), !meeting.changes.isEmpty {
                meetings.append(meeting)
            }
        }
        return meetings
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
        let calendar = AppConstants.taipeiCalendar
        var slots: [CourseTimeSlot] = []
        let dayKey = Self.dayKeyFormatter.string(from: date)

        for course in courses {
            guard let raw = course.schedule[weekday], !raw.isEmpty else { continue }
            let periods = raw.sortedByPeriodOrder()
            let dayChanges = changes.changes(courseNo: course.courseNo, on: date)

            var blockStart = 0
            while blockStart < periods.count {
                var blockEnd = blockStart
                // A meeting splits where a change covers only some of its periods.
                while blockEnd + 1 < periods.count,
                      Self.periodOrder(periods[blockEnd + 1]) == Self.periodOrder(periods[blockEnd]) + 1,
                      Self.reshaping(dayChanges, at: periods[blockEnd + 1])
                          == Self.reshaping(dayChanges, at: periods[blockEnd]) {
                    blockEnd += 1
                }
                let firstPeriod = periods[blockStart]
                let lastPeriod = periods[blockEnd]
                let run = Array(periods[blockStart...blockEnd])
                let applied = dayChanges.filter { run.contains(where: $0.covers) }
                if let firstTime = AppConstants.PeriodTimes.mapping[firstPeriod],
                   let lastTime = AppConstants.PeriodTimes.mapping[lastPeriod],
                   let startDate = Self.dateFromTimeString(firstTime.start, on: date, calendar: calendar),
                   let endDate = Self.dateFromTimeString(lastTime.end, on: date, calendar: calendar) {
                    let newStart = Self.changedTime(.start, in: applied, on: date)
                    let newEnd = Self.changedTime(.end, in: applied, on: date)
                    slots.append(CourseTimeSlot(
                        id: "\(course.courseNo)_\(dayKey)_\(firstPeriod)",
                        course: course,
                        start: newStart ?? startDate,
                        end: newEnd ?? endDate,
                        date: date,
                        periods: run,
                        changes: applied,
                        originalStart: newStart == nil ? nil : startDate,
                        originalEnd: newEnd == nil ? nil : endDate
                    ))
                }
                blockStart = blockEnd + 1
            }
        }

        return slots.sorted { $0.start < $1.start }
    }

    private static func reshaping(_ changes: [CourseChange], at period: String) -> [Int] {
        changes.filter { $0.kind != .note && $0.covers(period) }.map(\.id)
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
