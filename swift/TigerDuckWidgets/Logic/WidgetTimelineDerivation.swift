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
    }

    struct NextInfo: nonisolated Equatable, Sendable {
        let course: SnapshotCourse
        let startTime: String
        let periodRange: String
        let day: Day
        let classroom: String
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
        let order = snapshot.periodOrder
        let todayKey = dateKey(for: date)

        let isQuietToday = snapshot.quietDayKeys?.contains(todayKey) == true

        let ongoing = snapshot.courses.compactMap { course -> WidgetDerivedState.OngoingInfo? in
            if isQuietToday || course.skippedDates.contains(todayKey) { return nil }
            guard let raw = course.schedule[weekday] else { return nil }
            let periods = sortPeriods(raw, by: order)
            guard !periods.isEmpty else { return nil }
            for run in contiguousRuns(periods, by: order) {
                let first = run.first!
                let last = run.last!
                guard let firstStart = parseHm(snapshot.periodTimes[first]?.start),
                      let lastEnd = parseHm(snapshot.periodTimes[last]?.end),
                      nowMin >= firstStart, nowMin < lastEnd else { continue }
                let progress = lastEnd > firstStart
                    ? Double(nowMin - firstStart) / Double(lastEnd - firstStart)
                    : 0
                return .init(
                    course: course,
                    startTime: snapshot.periodTimes[first]?.start ?? "",
                    endTime: snapshot.periodTimes[last]?.end ?? "",
                    periodRange: run.count > 1 ? "\(first)–\(last)" : first,
                    progress: progress.clamped(to: 0...1),
                    classroom: course.classroom(weekday: weekday, periods: run)
                )
            }
            return nil
        }
        if !ongoing.isEmpty { return .ongoing(ongoing) }

        let candidates = snapshot.courses.compactMap { course -> (SnapshotCourse, Int, String)? in
            if isQuietToday || course.skippedDates.contains(todayKey) { return nil }
            guard let raw = course.schedule[weekday] else { return nil }
            let periods = sortPeriods(raw, by: order)
            for periodId in periods {
                if let start = parseHm(snapshot.periodTimes[periodId]?.start), start > nowMin {
                    return (course, start, periodId)
                }
            }
            return nil
        }
        if let pick = candidates.min(by: { $0.1 < $1.1 }) {
            return .nextToday(.init(
                course: pick.0,
                startTime: snapshot.periodTimes[pick.2]?.start ?? "",
                periodRange: pick.2,
                day: .today,
                classroom: blockClassroom(of: pick.0, weekday: weekday, startingAt: pick.2, order: order)
            ))
        }

        let calendar = WidgetTaipei.calendar
        for offset in 1...7 {
            let target = ((weekday - 1 + offset) % 7) + 1
            let targetDate = calendar.date(byAdding: .day, value: offset, to: date) ?? date
            let targetKey = dateKey(for: targetDate)
            if snapshot.quietDayKeys?.contains(targetKey) == true { continue }
            let dayCourses = snapshot.courses.compactMap { course -> (SnapshotCourse, String)? in
                if course.skippedDates.contains(targetKey) { return nil }
                guard let raw = course.schedule[target] else { return nil }
                let periods = sortPeriods(raw, by: order)
                guard let firstPeriod = periods.first else { return nil }
                return (course, firstPeriod)
            }
            if let pick = dayCourses.min(by: { lhs, rhs in
                let li = order.firstIndex(of: lhs.1) ?? Int.max
                let ri = order.firstIndex(of: rhs.1) ?? Int.max
                return li < ri
            }) {
                return .tomorrowFirst(.init(
                    course: pick.0,
                    startTime: snapshot.periodTimes[pick.1]?.start ?? "",
                    periodRange: pick.1,
                    day: offset == 1 ? .tomorrow : .later(weekday: target),
                    classroom: blockClassroom(of: pick.0, weekday: target, startingAt: pick.1, order: order)
                ))
            }
        }

        return .noMoreClasses
    }

    private static func blockClassroom(
        of course: SnapshotCourse,
        weekday: Int,
        startingAt periodId: String,
        order: [String]
    ) -> String {
        let runs = contiguousRuns(sortPeriods(course.schedule[weekday] ?? [], by: order), by: order)
        let block = runs.first { $0.first == periodId } ?? [periodId]
        return course.classroom(weekday: weekday, periods: block)
    }

    struct TodayRow: nonisolated Equatable, Identifiable, Sendable {
        let course: SnapshotCourse
        let periods: [String]
        let startTime: String
        let endTime: String
        let classroom: String

        var id: String { "\(course.courseNo)-\(periods[0])" }
        var periodRange: String { periods.count > 1 ? "\(periods[0])–\(periods[periods.count - 1])" : periods[0] }
    }

    static func todayRows(snapshot: WidgetSnapshot, at date: Date) -> [TodayRow] {
        let weekday = weekdayFor(date)
        let todayKey = dateKey(for: date)
        if snapshot.quietDayKeys?.contains(todayKey) == true { return [] }
        let order = snapshot.periodOrder
        let rows = snapshot.courses
            .filter { !$0.skippedDates.contains(todayKey) }
            .flatMap { course in
                contiguousRuns(sortPeriods(course.schedule[weekday] ?? [], by: order), by: order).map { run in
                    TodayRow(
                        course: course,
                        periods: run,
                        startTime: snapshot.periodTimes[run[0]]?.start ?? "",
                        endTime: snapshot.periodTimes[run[run.count - 1]]?.end ?? "",
                        classroom: course.classroom(weekday: weekday, periods: run)
                    )
                }
            }
        return rows.sorted { lhs, rhs in
            (order.firstIndex(of: lhs.periods[0]) ?? Int.max) < (order.firstIndex(of: rhs.periods[0]) ?? Int.max)
        }
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

        for course in snapshot.courses {
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
