import Foundation

extension Date {
    var shortDateString: String {
        formatted(.dateTime.month(.defaultDigits).day())
    }

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
        case 5..<12: return "早安"
        case 12..<18: return "午安"
        default: return "晚安"
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

    /// Relative time: "5 天後", "30 小時後", "3 小時後", "已逾期"
    func relativeTimeString(from now: Date) -> String {
        let interval = timeIntervalSince(now)
        if interval < 0 {
            return "已逾期"
        }
        let days = Int(interval / 86400)
        if days > 3 {
            return "\(days) 天後"
        }
        let hours = Int(interval / 3600)
        if hours > 0 {
            return "\(hours) 小時後"
        }
        let minutes = Int(interval / 60)
        if minutes > 0 {
            return "\(minutes) 分鐘後"
        }
        return "\(interval) 秒鐘後"
    }
}
