import Foundation

enum WidgetDerivedState: nonisolated Equatable, Sendable {
    case signInRequired
    case ongoing([OngoingInfo])
    case nextToday(NextInfo)
    case tomorrowFirst(NextInfo)
    case noMoreClasses

    struct OngoingInfo: nonisolated Equatable, Sendable {
        let course: SnapshotCourse
        let startTime: String
        let endTime: String
        let periodRange: String
        let progress: Double
        let classroom: String
        var change: SnapshotCourseChange? = nil
    }

    struct NextInfo: nonisolated Equatable, Sendable {
        let course: SnapshotCourse
        let startTime: String
        let periodRange: String
        let day: Day
        let classroom: String
        var change: SnapshotCourseChange? = nil
    }

    enum Day: nonisolated Equatable, Sendable {
        case today
        case tomorrow
        case later(weekday: Int)
    }
}

enum WidgetTimelineDerivation {
    static func derive(snapshot: WidgetSnapshot, at date: Date) -> WidgetDerivedState {
        guard snapshot.isLoggedIn else { return .signInRequired }
        guard !snapshot.courses.isEmpty else { return .noMoreClasses }

        let weekday = weekdayFor(date)
        let nowMin = minuteOfDayFor(date)
        let todayKey = dateKey(for: date)

        let isQuietToday = snapshot.quietDayKeys?.contains(todayKey) == true

        let ongoing = snapshot.courses.compactMap { course -> WidgetDerivedState.OngoingInfo? in
            if isQuietToday || course.skippedDates.contains(todayKey) { return nil }
            for meeting in meetings(of: course, on: date, in: snapshot) {
                guard !meeting.isCancelled,
                      let firstStart = parseHm(meeting.startTime),
                      let lastEnd = parseHm(meeting.endTime),
                      nowMin >= firstStart, nowMin < lastEnd else { continue }
                let progress = lastEnd > firstStart
                    ? Double(nowMin - firstStart) / Double(lastEnd - firstStart)
                    : 0
                return .init(
                    course: course,
                    startTime: meeting.startTime,
                    endTime: meeting.endTime,
                    periodRange: meeting.periodRange,
                    progress: progress.clamped(to: 0...1),
                    classroom: meeting.classroom,
                    change: meeting.change
                )
            }
            return nil
        }
        if !ongoing.isEmpty { return .ongoing(ongoing) }

        let candidates = snapshot.courses.compactMap { course -> (TodayRow, Int)? in
            if isQuietToday || course.skippedDates.contains(todayKey) { return nil }
            return meetings(of: course, on: date, in: snapshot).lazy
                .filter { !$0.isCancelled }
                .compactMap { meeting in parseHm(meeting.startTime).map { (meeting, $0) } }
                .first { $0.1 > nowMin }
        }
        if let pick = candidates.min(by: { $0.1 < $1.1 }) {
            return .nextToday(.init(
                course: pick.0.course,
                startTime: pick.0.startTime,
                periodRange: pick.0.periods[0],
                day: .today,
                classroom: pick.0.classroom,
                change: pick.0.change
            ))
        }

        let calendar = WidgetTaipei.calendar
        for offset in 1...7 {
            let target = ((weekday - 1 + offset) % 7) + 1
            let targetDate = calendar.date(byAdding: .day, value: offset, to: date) ?? date
            let targetKey = dateKey(for: targetDate)
            if snapshot.quietDayKeys?.contains(targetKey) == true { continue }
            let dayCourses = snapshot.courses.compactMap { course -> TodayRow? in
                if course.skippedDates.contains(targetKey) { return nil }
                return meetings(of: course, on: targetDate, in: snapshot).first { !$0.isCancelled }
            }
            if let pick = dayCourses.min(by: { (parseHm($0.startTime) ?? .max) < (parseHm($1.startTime) ?? .max) }) {
                return .tomorrowFirst(.init(
                    course: pick.course,
                    startTime: pick.startTime,
                    periodRange: pick.periods[0],
                    day: offset == 1 ? .tomorrow : .later(weekday: target),
                    classroom: pick.classroom,
                    change: pick.change
                ))
            }
        }

        return .noMoreClasses
    }

    struct TodayRow: nonisolated Equatable, Identifiable, Sendable {
        let course: SnapshotCourse
        let periods: [String]
        let startTime: String
        let endTime: String
        let classroom: String
        var change: SnapshotCourseChange? = nil

        var id: String { "\(course.courseNo)-\(periods[0])" }
        var periodRange: String { periods.count > 1 ? "\(periods[0])–\(periods[periods.count - 1])" : periods[0] }
        var isCancelled: Bool { change?.cancelled == true }
    }

    /// The course's meetings on a day, earliest first, with the day's changed room and times in
    /// place; a changed time can put a later period's meeting first.
    static func meetings(of course: SnapshotCourse, on date: Date, in snapshot: WidgetSnapshot) -> [TodayRow] {
        let weekday = weekdayFor(date)
        let key = dateKey(for: date)
        let order = snapshot.periodOrder
        return contiguousRuns(sortPeriods(course.schedule[weekday] ?? [], by: order), by: order).map { run in
            let change = course.change(on: key, startingAt: run.first)
            return TodayRow(
                course: course,
                periods: run,
                startTime: change?.start ?? snapshot.periodTimes[run[0]]?.start ?? "",
                endTime: change?.end ?? snapshot.periodTimes[run[run.count - 1]]?.end ?? "",
                classroom: change?.room ?? course.classroom(weekday: weekday, periods: run),
                change: change
            )
        }
        .sorted { (parseHm($0.startTime) ?? .max) < (parseHm($1.startTime) ?? .max) }
    }

    static func todayRows(snapshot: WidgetSnapshot, at date: Date) -> [TodayRow] {
        let todayKey = dateKey(for: date)
        if snapshot.quietDayKeys?.contains(todayKey) == true { return [] }
        let order = snapshot.periodOrder
        let rows = snapshot.courses
            .filter { !$0.skippedDates.contains(todayKey) }
            .flatMap { meetings(of: $0, on: date, in: snapshot) }
        func key(_ row: TodayRow) -> (Int, Int) {
            (parseHm(row.startTime) ?? .max, order.firstIndex(of: row.periods[0]) ?? .max)
        }
        return rows.sorted { key($0) < key($1) }
    }

    static func dateKey(for date: Date) -> String {
        return Self.dateKeyFormatter.string(from: date)
    }

    private static let dateKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = WidgetTaipei.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func weekdayFor(_ date: Date) -> Int {
        let raw = WidgetTaipei.calendar.component(.weekday, from: date)
        return raw == 1 ? 7 : raw - 1
    }

    static func minuteOfDayFor(_ date: Date) -> Int {
        let cal = WidgetTaipei.calendar
        let h = cal.component(.hour, from: date)
        let m = cal.component(.minute, from: date)
        return h * 60 + m
    }

    static func parseHm(_ string: String?) -> Int? {
        guard let s = string else { return nil }
        let parts = s.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }

    /// keep the call sites simple — inlining this in `.sorted(by:)` triggers
    /// "unable to type-check in reasonable time" because of the optional
    /// `firstIndex(of:)` + `?? .max` interaction with surrounding closures.
    static func sortPeriods(_ periods: [String], by order: [String]) -> [String] {
        periods.sorted { lhs, rhs in
            let li = order.firstIndex(of: lhs) ?? Int.max
            let ri = order.firstIndex(of: rhs) ?? Int.max
            return li < ri
        }
    }

    static func contiguousRuns(_ periods: [String], by order: [String]) -> [[String]] {
        var runs: [[String]] = []
        var current: [String] = []
        var prevIndex = Int.min
        for period in periods {
            let idx = order.firstIndex(of: period) ?? Int.min
            if !current.isEmpty, idx == prevIndex + 1 {
                current.append(period)
            } else {
                if !current.isEmpty { runs.append(current) }
                current = [period]
            }
            prevIndex = idx
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

extension WidgetTimelineDerivation {
    /// The first Taipei midnight after `date`, when a widget with nothing to show asks again.
    /// A single entry with `.atEnd` would make WidgetKit reload it at once, over and over; the
    /// app reloads every timeline itself when it writes a snapshot.
    static func nextMidnight(after date: Date, calendar: Calendar = WidgetTaipei.calendar) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: startOfDay)
            ?? startOfDay.addingTimeInterval(86_400)
    }

    static func entryDates(
        snapshot: WidgetSnapshot,
        after now: Date,
        calendar: Calendar = WidgetTaipei.calendar
    ) -> [Date] {
        var result: Set<Date> = [now]
        let weekday = weekdayFor(now)
        let dayStart = calendar.startOfDay(for: now)

        let todayKey = dateKey(for: now)
        for course in snapshot.courses {
            for change in course.changes where change.day == todayKey {
                for time in [change.start, change.end].compactMap({ parseHm($0) }) {
                    if let date = calendar.date(byAdding: .minute, value: time, to: dayStart), date > now {
                        result.insert(date)
                    }
                }
            }
            guard let periods = course.schedule[weekday] else { continue }
            for periodId in periods {
                guard let pt = snapshot.periodTimes[periodId] else { continue }
                if let start = parseHm(pt.start),
                   let date = calendar.date(byAdding: .minute, value: start, to: dayStart),
                   date > now {
                    result.insert(date)
                }
                if let end = parseHm(pt.end),
                   let date = calendar.date(byAdding: .minute, value: end, to: dayStart),
                   date > now {
                    result.insert(date)
                }
            }
        }

        if let midnight = calendar.date(byAdding: .day, value: 1, to: dayStart) {
            result.insert(midnight)
        }

        return result.sorted()
    }
}
