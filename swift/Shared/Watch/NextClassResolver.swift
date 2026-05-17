import Foundation

public enum NextClassResolver {

    public struct Result: Equatable {
        public let current: WatchCourse?
        public let next: WatchCourse?
    }

    /// Given the watch's full course list and the current instant, return
    /// the class currently in progress (if any) and the next class to start
    /// today (if any). Other weekdays are ignored.
    public static func resolve(courses: [WatchCourse], now: Date) -> Result {
        // Pinned to Taipei: NTUST's class times are authored in Taiwan
        // wall time, so the watch must answer "what's happening now" in
        // that frame regardless of where the wearer is physically. Without
        // the pin a student abroad would see no classes during what is
        // morning in Taipei.
        let cal = SharedTaipei.calendar
        // Gregorian weekday: 1=Sun..7=Sat; convert to 1=Mon..7=Sun.
        let raw = cal.component(.weekday, from: now)
        let isoWeekday = ((raw + 5) % 7) + 1

        let hh = cal.component(.hour, from: now)
        let mm = cal.component(.minute, from: now)
        let nowMin = hh * 60 + mm

        let today = courses
            .filter { $0.weekday == isoWeekday }
            .sorted { minutes(of: $0.startHHmm) < minutes(of: $1.startHHmm) }

        let current = today.first { c in
            let s = minutes(of: c.startHHmm)
            let e = minutes(of: c.endHHmm)
            return nowMin >= s && nowMin < e
        }

        let next = today.first { c in
            minutes(of: c.startHHmm) > nowMin
        }

        return Result(current: current, next: next)
    }

    private static func minutes(of hhmm: String) -> Int {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]),
              let m = Int(parts[1]) else { return 0 }
        return h * 60 + m
    }
}
