import Foundation

public enum NextClassResolver {

    public struct Result: Equatable {
        public let current: WatchCourse?
        public let next: WatchCourse?
    }

    /// Given the watch's full course list and the current instant, return
    /// the class currently in progress (if any) and the next class the wearer
    /// still has to get to today (if any). Other weekdays are ignored, and so
    /// are today's classes when today is in `quietDays` or a course skips it.
    public static func resolve(courses: [WatchCourse], now: Date, quietDays: Set<String> = []) -> Result {
        let today = todaysClasses(courses: courses, now: now, quietDays: quietDays)
        // Taipei, not the device zone: class times are Taiwan wall time, so a
        // wearer abroad must still see "now" in that frame. Without the pin
        // they would see no classes during the Taipei morning.
        let cal = SharedTaipei.calendar
        let hh = cal.component(.hour, from: now)
        let mm = cal.component(.minute, from: now)
        let nowMin = hh * 60 + mm

        let current = today.first { c in
            let s = minutes(of: c.startHHmm)
            let e = minutes(of: c.endHHmm)
            return nowMin >= s && nowMin < e
        }

        // `next` is the first class not yet over, not the next to start: when two
        // classes overlap, the later one has already started and `current` holds
        // the earlier, so it would vanish. Conflicting enrolments are a modelled state.
        let next = today.first { c in
            c.id != current?.id && minutes(of: c.endHHmm) > nowMin
        }

        return Result(current: current, next: next)
    }

    /// Today's classes in start order, as the Today tab lists them and `resolve` reads them.
    /// Empty when today is in `quietDays`; a course that skips today is left out.
    public static func todaysClasses(courses: [WatchCourse], now: Date, quietDays: Set<String>) -> [WatchCourse] {
        let todayKey = SharedTaipei.dayKey(for: now)
        guard !quietDays.contains(todayKey) else { return [] }
        // Gregorian weekday: 1=Sun..7=Sat; convert to 1=Mon..7=Sun.
        let raw = SharedTaipei.calendar.component(.weekday, from: now)
        let isoWeekday = ((raw + 5) % 7) + 1
        return courses
            .filter { $0.weekday == isoWeekday && $0.skippedDates?.contains(todayKey) != true }
            .sorted { minutes(of: $0.startHHmm) < minutes(of: $1.startHHmm) }
    }

    private static func minutes(of hhmm: String) -> Int {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]),
              let m = Int(parts[1]) else { return 0 }
        return h * 60 + m
    }
}
