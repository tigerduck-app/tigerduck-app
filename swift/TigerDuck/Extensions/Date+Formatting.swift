import Foundation

extension Date {
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
        return f
    }()

    var timeString: String {
        formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    var weekdayIndex: Int {
        // 1=Sunday ... 7=Saturday → convert to 0=Monday ... 6=Sunday
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: self)
        return (weekday + 5) % 7
    }

    /// 1-based weekday key used in SDCourse.schedule (1=Monday … 7=Sunday)
    var scheduleWeekday: Int { weekdayIndex + 1 }

    var isToday: Bool {
        Calendar.current.isDateInToday(self)
    }

    func isSameDay(as other: Date) -> Bool {
        Calendar.current.isDate(self, inSameDayAs: other)
    }

    var startOfDay: Date {
        Calendar.current.startOfDay(for: self)
    }

    var startOfMonth: Date {
        let components = Calendar.current.dateComponents([.year, .month], from: self)
        return Calendar.current.date(from: components)!
    }

    var daysInMonth: Int {
        Calendar.current.range(of: .day, in: .month, for: self)!.count
    }

    var firstWeekdayOfMonth: Int {
        let first = startOfMonth
        return Calendar.current.component(.weekday, from: first)
    }

    func greetingText() -> String {
        let hour = Calendar.current.component(.hour, from: self)
        switch hour {
        case 5..<12: return String(localized: "greeting_morning")
        case 12..<18: return String(localized: "greeting_afternoon")
        default: return String(localized: "greeting_evening")
        }
    }

    private static let absoluteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d HH:mm:ss"
        return f
    }()

    /// Absolute time: "3/24 23:59:00"
    var absoluteTimeString: String {
        Self.absoluteFormatter.string(from: self)
    }

    /// Relative time, e.g. "5 days later", "30 hours later", or "Overdue".
    func relativeTimeString(from now: Date) -> String {
        let interval = timeIntervalSince(now)
        if interval < 0 {
            return String(localized: "assignment_status_overdue")
        }
        let suffix = String(localized: "assignment_time_suffix_later")
        let days = Int(interval / 86400)
        if days > 3 {
            return String(format: String(localized: "assignment_time_days_with_suffix"), days, suffix)
        }
        let hours = Int(interval / 3600)
        if hours > 0 {
            return String(format: String(localized: "assignment_time_hours_with_suffix"), hours, suffix)
        }
        let minutes = Int(interval / 60)
        if minutes > 0 {
            return String(format: String(localized: "assignment_time_minutes_with_suffix"), minutes, suffix)
        }
        return String(format: String(localized: "assignment_time_seconds_with_suffix"), Int(interval), suffix)
    }
}
