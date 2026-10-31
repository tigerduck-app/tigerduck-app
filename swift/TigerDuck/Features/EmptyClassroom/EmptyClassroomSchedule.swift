import Foundation
import TigerDuckCore

nonisolated enum EmptyClassroomSchedule {
    static let periodIDs = AppConstants.Periods.chronologicalOrder

    static let periodMinutes: [(start: Int, end: Int)] = periodIDs.compactMap { id in
        guard let times = AppConstants.PeriodTimes.mapping[id],
              let start = minutes(times.start), let end = minutes(times.end) else { return nil }
        return (start, end)
    }

    static func timeRange(of period: Int) -> (start: String, end: String)? {
        guard periodIDs.indices.contains(period) else { return nil }
        return AppConstants.PeriodTimes.mapping[periodIDs[period]]
    }

    static func periods(from start: Date, to end: Date, calendar: Calendar = TaipeiTime.calendar) -> [Int] {
        let from = minuteOfDay(start, calendar: calendar)
        let to = minuteOfDay(end, calendar: calendar)
        return periodMinutes.indices.filter { periodMinutes[$0].start < to && periodMinutes[$0].end > from }
    }

    static func upcomingPeriod(at time: Date, calendar: Calendar = TaipeiTime.calendar) -> Int? {
        let minute = minuteOfDay(time, calendar: calendar)
        return periodMinutes.firstIndex { $0.end > minute }
    }

    static func endedPeriods(at time: Date, calendar: Calendar = TaipeiTime.calendar) -> Int {
        let minute = minuteOfDay(time, calendar: calendar)
        return periodMinutes.filter { $0.end <= minute }.count
    }

    static func opening(
        at now: Date,
        horizon: Int,
        isTeachingDay: (Date) -> Bool,
        calendar: Calendar = TaipeiTime.calendar
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
        calendar: Calendar = TaipeiTime.calendar
    ) -> Date? {
        guard horizon > 0 else { return nil }
        let start = calendar.startOfDay(for: day)
        return (1...horizon).lazy
            .compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
            .first(where: isTeachingDay)
    }

    nonisolated enum DayOff: Equatable {
        case weekend
        case holiday(Holiday)
        case outOfTerm
    }

    /// Why `day` has no rooms to show, or nil on a teaching day. The booking system shows the
    /// weekly timetable on a holiday and between terms as if classes met, and nothing at all on a
    /// weekend (https://github.com/tigerduck-app/tigerduck-app/issues/478).
    static func dayOff(
        _ day: Date,
        holidays: (Date) -> [Holiday],
        isInSession: (Date) -> Bool,
        calendar: Calendar = TaipeiTime.calendar
    ) -> DayOff? {
        if isWeekend(day, calendar: calendar) { return .weekend }
        if let holiday = holidays(day).first { return .holiday(holiday) }
        return isInSession(day) ? nil : .outOfTerm
    }

    static func isWeekend(_ day: Date, calendar: Calendar = TaipeiTime.calendar) -> Bool {
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
