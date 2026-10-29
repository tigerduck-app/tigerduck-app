import Foundation

public nonisolated enum NextClassResolver {

    public struct Result: Equatable {
        public let current: WatchCourse?
        public let next: WatchCourse?
        public let nextDay: Day
    }

    public nonisolated enum Day: Equatable, Sendable {
        case today
        case tomorrow
        case later(weekday: Int)

        public func headline(in language: WatchLanguage) -> String {
            switch self {
            case .today: return language.string("watch_next")
            case .tomorrow: return language.string("widget_tomorrow")
            case .later(let weekday): return Self.caption(of: weekday, in: language)
            }
        }

        public func inlineCaption(_ time: String, in language: WatchLanguage) -> String {
            switch self {
            case .today:
                return time
            case .tomorrow:
                return language.format("widget_tomorrow_time", time)
            case .later(let weekday):
                return "\(Self.caption(of: weekday, in: language)) \(time)"
            }
        }

        private static func caption(of weekday: Int, in language: WatchLanguage) -> String {
            switch weekday {
            case 1: return language.string("weekday_mon_caption")
            case 2: return language.string("weekday_tue_caption")
            case 3: return language.string("weekday_wed_caption")
            case 4: return language.string("weekday_thu_caption")
            case 5: return language.string("weekday_fri_caption")
            case 6: return language.string("weekday_sat_caption")
            default: return language.string("weekday_sun_caption")
            }
        }
    }

    public static func resolve(courses: [WatchCourse], now: Date, quietDays: Set<String> = []) -> Result {
        let today = todaysClasses(courses: courses, now: now, quietDays: quietDays)
        let cal = SharedTaipei.calendar
        let hh = cal.component(.hour, from: now)
        let mm = cal.component(.minute, from: now)
        let nowMin = hh * 60 + mm

        let current = today.first { c in
            let s = minutes(of: c.startHHmm)
            let e = minutes(of: c.endHHmm)
            return nowMin >= s && nowMin < e
        }

        let next = today.first { c in
            c.id != current?.id && minutes(of: c.endHHmm) > nowMin
        }

        if current != nil || next != nil {
            return Result(current: current, next: next, nextDay: .today)
        }
        return firstClassAhead(courses: courses, after: now, quietDays: quietDays)
    }

    public static func todaysClasses(courses: [WatchCourse], now: Date, quietDays: Set<String>) -> [WatchCourse] {
        let todayKey = SharedTaipei.dayKey(for: now)
        guard !quietDays.contains(todayKey) else { return [] }
        let raw = SharedTaipei.calendar.component(.weekday, from: now)
        let isoWeekday = ((raw + 5) % 7) + 1
        return courses
            .filter { $0.weekday == isoWeekday && $0.skippedDates?.contains(todayKey) != true }
            .flatMap { $0.on(todayKey) }
            .sorted { minutes(of: $0.startHHmm) < minutes(of: $1.startHHmm) }
    }

    private static func firstClassAhead(courses: [WatchCourse], after now: Date, quietDays: Set<String>) -> Result {
        for offset in 1...7 {
            guard let day = SharedTaipei.calendar.date(byAdding: .day, value: offset, to: now),
                  let first = todaysClasses(courses: courses, now: day, quietDays: quietDays).first
            else { continue }
            let nextDay: Day = offset == 1 ? .tomorrow : .later(weekday: first.weekday)
            return Result(current: nil, next: first, nextDay: nextDay)
        }
        return Result(current: nil, next: nil, nextDay: .today)
    }

    private static func minutes(of hhmm: String) -> Int {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]),
              let m = Int(parts[1]) else { return 0 }
        return h * 60 + m
    }
}
