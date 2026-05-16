import Foundation

enum WidgetDerivedState: Equatable, Sendable {
    case signInRequired
    case ongoing([OngoingInfo])
    case nextToday(NextInfo)
    case tomorrowFirst(NextInfo)
    case noMoreClasses

    struct OngoingInfo: Equatable, Sendable {
        let course: SnapshotCourse
        let startTime: String              // "HH:mm"
        let endTime: String
        let periodRange: String            // "B" or "B–C"
        let progress: Double               // 0.0…1.0
    }

    struct NextInfo: Equatable, Sendable {
        let course: SnapshotCourse
        let startTime: String
        let periodRange: String
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

        // 1. Ongoing courses — only when `nowMin` falls inside a contiguous run
        // of scheduled periods. A course with non-adjacent slots (e.g. A and C
        // with B unscheduled) splits into two singleton runs, so the gap
        // between them correctly falls through to the next-class branch
        // instead of marking the course as still ongoing across the gap.
        let ongoing = snapshot.courses.compactMap { course -> WidgetDerivedState.OngoingInfo? in
            if course.skippedDates.contains(todayKey) { return nil }
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
                    progress: progress.clamped(to: 0...1)
                )
            }
            return nil
        }
        if !ongoing.isEmpty { return .ongoing(ongoing) }

        // 2. Next today (any course whose first period today starts in the future)
        let candidates = snapshot.courses.compactMap { course -> (SnapshotCourse, Int, String)? in
            if course.skippedDates.contains(todayKey) { return nil }
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
                periodRange: pick.2
            ))
        }

        // 3. Tomorrow first: scan ahead up to 7 weekdays
        let calendar = Calendar(identifier: .gregorian)
        for offset in 1...7 {
            let target = ((weekday - 1 + offset) % 7) + 1
            let targetDate = calendar.date(byAdding: .day, value: offset, to: date) ?? date
            let targetKey = dateKey(for: targetDate)
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
                    periodRange: pick.1
                ))
            }
        }

        return .noMoreClasses
    }

    /// `yyyy-MM-dd` in the device's time zone — must mirror `SDCourse.isoFormatter`
    /// so a `Set<String>` lookup against `SnapshotCourse.skippedDates` matches.
    static func dateKey(for date: Date) -> String {
        return Self.dateKeyFormatter.string(from: date)
    }

    private static let dateKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: - Helpers

    /// Returns 1=Mon … 7=Sun. Pinned to the gregorian calendar so device
    /// locale calendars (e.g. ROC, Buddhist) don't shift weekday math
    /// against NTUST's gregorian-based schedule.
    static func weekdayFor(_ date: Date) -> Int {
        let raw = Calendar(identifier: .gregorian).component(.weekday, from: date)
        return raw == 1 ? 7 : raw - 1
    }

    static func minuteOfDayFor(_ date: Date) -> Int {
        let cal = Calendar(identifier: .gregorian)
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

    /// Sort a list of period IDs by their position in `order`. Period IDs not
    /// present in `order` sink to the end (Int.max placeholder). Extracted to
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

    /// Split a chronologically sorted list of period IDs into contiguous runs
    /// where each successive entry occupies the next slot in `order`. For
    /// `order = ["A","B","C","D"]` and `periods = ["A","C","D"]` the result is
    /// `[["A"], ["C","D"]]`, so the unscheduled gap at `B` is preserved
    /// instead of being absorbed into a single envelope. Periods missing from
    /// `order` always start a new run.
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
    /// Returns the set of `Date`s at which the widget should refresh:
    ///   - `now` itself
    ///   - every remaining period start AND end today
    ///   - midnight at the start of tomorrow
    ///
    /// Deduplicated and sorted ascending. Callers feed these into
    /// `TimelineEntry` construction so each entry's `derive(at:)` lands
    /// exactly on a meaningful boundary (period start/end, day change),
    /// avoiding wasted refreshes mid-period.
    static func entryDates(
        snapshot: WidgetSnapshot,
        after now: Date,
        calendar: Calendar = Calendar(identifier: .gregorian)
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
