import Foundation

/// Period and day math for the finder: the 14 periods by index (0 is period 1, 13 is D), and
/// which day and period it opens on.
nonisolated enum EmptyClassroomSchedule {
    static let periodIDs = AppConstants.Periods.chronologicalOrder

    /// Each period's start and end, in minutes after midnight.
    static let periodMinutes: [(start: Int, end: Int)] = periodIDs.compactMap { id in
        guard let times = AppConstants.PeriodTimes.mapping[id],
              let start = minutes(times.start), let end = minutes(times.end) else { return nil }
        return (start, end)
    }

    static func timeRange(of period: Int) -> (start: String, end: String)? {
        guard periodIDs.indices.contains(period) else { return nil }
        return AppConstants.PeriodTimes.mapping[periodIDs[period]]
    }

    /// The period in progress at `time`, or during a break the next one; nil after the last.
    static func upcomingPeriod(at time: Date, calendar: Calendar = AppConstants.taipeiCalendar) -> Int? {
        let minute = minuteOfDay(time, calendar: calendar)
        return periodMinutes.firstIndex { $0.end > minute }
    }

    /// How many of the day's periods have ended at `time`.
    static func endedPeriods(at time: Date, calendar: Calendar = AppConstants.taipeiCalendar) -> Int {
        let minute = minuteOfDay(time, calendar: calendar)
        return periodMinutes.filter { $0.end <= minute }.count
    }

    /// Where the now line sits: the period it falls in and how far through it, or the start of
    /// the next period during a break. Nil before the first period starts and after the last.
    static func nowPosition(at time: Date, calendar: Calendar = AppConstants.taipeiCalendar) -> (period: Int, fraction: Double)? {
        let minute = minuteOfDay(time, calendar: calendar)
        guard let period = upcomingPeriod(at: time, calendar: calendar),
              period > 0 || minute >= periodMinutes[0].start else { return nil }
        let span = periodMinutes[period]
        let fraction = Double(minute - span.start) / Double(span.end - span.start)
        return (period, min(max(fraction, 0), 1))
    }

    /// The day and period the finder opens on: the current period, or the next one during a
    /// break; after the last period, and on a day without classes, the first period of the next
    /// teaching day within `horizon` days.
    static func opening(
        at now: Date,
        horizon: Int,
        isTeachingDay: (Date) -> Bool,
        calendar: Calendar = AppConstants.taipeiCalendar
    ) -> (day: Date, period: Int) {
        let today = calendar.startOfDay(for: now)
        let upcoming = upcomingPeriod(at: now, calendar: calendar)
        if isTeachingDay(today), let upcoming { return (today, upcoming) }
        if let next = nextTeachingDay(after: today, horizon: horizon, isTeachingDay: isTeachingDay, calendar: calendar) {
            return (next, 0)
        }
        return (today, upcoming ?? 0)
    }

    static func nextTeachingDay(
        after day: Date,
        horizon: Int,
        isTeachingDay: (Date) -> Bool,
        calendar: Calendar = AppConstants.taipeiCalendar
    ) -> Date? {
        guard horizon > 0 else { return nil }
        let start = calendar.startOfDay(for: day)
        return (1...horizon).lazy
            .compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
            .first(where: isTeachingDay)
    }

    /// A weekday with no holiday: the booking system shows the weekly timetable on a holiday as
    /// if classes met, and nothing at all on a weekend.
    static func isTeachingDay(
        _ day: Date,
        holidays: (Date) -> [Holiday],
        calendar: Calendar = AppConstants.taipeiCalendar
    ) -> Bool {
        !isWeekend(day, calendar: calendar) && holidays(day).isEmpty
    }

    static func isWeekend(_ day: Date, calendar: Calendar = AppConstants.taipeiCalendar) -> Bool {
        let weekday = calendar.component(.weekday, from: day)
        return weekday == 1 || weekday == 7
    }

    private static func minutes(_ time: String) -> Int? {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return parts[0] * 60 + parts[1]
    }

    private static func minuteOfDay(_ time: Date, calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}
