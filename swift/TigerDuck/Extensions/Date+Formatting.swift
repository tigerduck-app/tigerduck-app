import Foundation

extension Date {
    /// Gregorian + Asia/Taipei calendar pinned for every schedule-math
    /// helper below. NTUST's class table, semester boundaries, and ICS
    /// feeds are gregorian — using `Calendar.current` would shift
    /// month/day arithmetic on a device set to ROC or Buddhist calendar
    /// (already proven by `SDCourse.isoFormatter` pinning the same way).
    static let scheduleCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Taipei") ?? .current
        return cal
    }()

    var shortDateString: String {
        formatted(.dateTime.month(.defaultDigits).day())
    }

    /// Full numeric date — "2026/04/23". Used for article mastheads where
    /// the year matters and truncating to M/d would read as ambiguous.
    var fullDateString: String {
        Self.fullDateFormatter.string(from: self)
    }

    private static let fullDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd"
        // Pin to gregorian + en_US_POSIX so a device set to ROC /
        // Buddhist calendar doesn't render `2026-04-23` as `0115/04/23`.
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        return f
    }()

    var timeString: String {
        formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    var weekdayIndex: Int {
        // 1=Sunday ... 7=Saturday → convert to 0=Monday ... 6=Sunday
        let weekday = Self.scheduleCalendar.component(.weekday, from: self)
        return (weekday + 5) % 7
    }

    /// 1-based weekday key used in SDCourse.schedule (1=Monday … 7=Sunday)
    var scheduleWeekday: Int { weekdayIndex + 1 }

    var isToday: Bool {
        Self.scheduleCalendar.isDateInToday(self)
    }

    func isSameDay(as other: Date) -> Bool {
        Self.scheduleCalendar.isDate(self, inSameDayAs: other)
    }

    var startOfDay: Date {
        Self.scheduleCalendar.startOfDay(for: self)
    }

    var startOfMonth: Date {
        let components = Self.scheduleCalendar.dateComponents([.year, .month], from: self)
        return Self.scheduleCalendar.date(from: components) ?? self
    }

    var daysInMonth: Int {
        Self.scheduleCalendar.range(of: .day, in: .month, for: self)?.count ?? 30
    }

    var firstWeekdayOfMonth: Int {
        let first = startOfMonth
        return Self.scheduleCalendar.component(.weekday, from: first)
    }

    func greetingText() -> String {
        let hour = Self.scheduleCalendar.component(.hour, from: self)
        switch hour {
        case 5..<12: return String(localized: "greeting_morning")
        case 12..<18: return String(localized: "greeting_afternoon")
        default: return String(localized: "greeting_evening")
        }
    }

    private static let absoluteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        return f
    }()

    /// Absolute time: "3/24 23:59:00"
    var absoluteTimeString: String {
        Self.absoluteFormatter.string(from: self)
    }

    /// Relative time, e.g. "5 days later", "30 hours later", or "Overdue".
    /// `<= 0` reads as overdue (a deadline at the exact current second is no
    /// longer "later"); buckets round up so the user never sees "0 minutes
    /// later" — a value just below the next bucket should display as that
    /// bucket.
    func relativeTimeString(from now: Date) -> String {
        let interval = timeIntervalSince(now)
        if interval <= 0 {
            return String(localized: "assignment_status_overdue")
        }
        let suffix = String(localized: "assignment_time_suffix_later")
        let days = Int(ceil(interval / 86400))
        if days > 3 {
            return String(format: String(localized: "assignment_time_days_with_suffix"), days, suffix)
        }
        let hours = Int(ceil(interval / 3600))
        if hours > 0 {
            return String(format: String(localized: "assignment_time_hours_with_suffix"), hours, suffix)
        }
        let minutes = Int(ceil(interval / 60))
        if minutes > 0 {
            return String(format: String(localized: "assignment_time_minutes_with_suffix"), minutes, suffix)
        }
        return String(format: String(localized: "assignment_time_seconds_with_suffix"), max(1, Int(ceil(interval))), suffix)
    }
}
