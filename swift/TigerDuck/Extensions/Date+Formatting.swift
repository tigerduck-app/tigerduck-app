import Foundation

extension Date {
    static let scheduleCalendar: Calendar = AppConstants.taipeiCalendar

    var shortDateString: String {
        var style = Date.FormatStyle.dateTime.month(.defaultDigits).day()
        style.timeZone = AppConstants.taipeiTimeZone
        return formatted(style)
    }

    var fullDateString: String {
        Self.fullDateFormatter.string(from: self)
    }

    private static let fullDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd"
        // Pin to gregorian + en_US_POSIX so a device set to ROC /
        // Buddhist calendar doesn't render `2026-04-23` as `0115/04/23`.
        // Pin time zone too so a traveler sees Taipei's calendar day.
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = AppConstants.taipeiTimeZone
        return f
    }()

    /// `HH:mm` in Taipei time, on a 24-hour clock in every locale as the class times are; a
    /// 12-hour locale's hour cycle without its AM or PM would show 20:03 as 08:03.
    var timeString: String {
        formatted(Self.timeStyle)
    }

    static let timeStyle = Date.VerbatimFormatStyle(
        format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
        timeZone: AppConstants.taipeiTimeZone,
        calendar: AppConstants.taipeiCalendar
    )

    func moodleListDateString(now: Date = AppClock.now()) -> String {
        if isSameDay(as: now) { return timeString }
        return moodleDateString(now: now)
    }

    func moodleDateString(now: Date = AppClock.now()) -> String {
        let calendar = Self.scheduleCalendar
        let thisYear = calendar.component(.year, from: self) == calendar.component(.year, from: now)
        return (thisYear ? Self.moodleMonthDayFormatter : Self.fullDateFormatter).string(from: self)
    }

    var moodleDateTimeString: String {
        Self.moodleDateTimeFormatter.string(from: self)
    }

    func moodlePostDateString(now: Date = AppClock.now()) -> String {
        let calendar = Self.scheduleCalendar
        let thisYear = calendar.component(.year, from: self) == calendar.component(.year, from: now)
        return (thisYear ? Self.moodleMonthDayTimeFormatter : Self.moodleDateTimeFormatter).string(from: self)
    }

    private static let moodleMonthDayFormatter = posixFormatter("MM/dd")
    private static let moodleMonthDayTimeFormatter = posixFormatter("MM/dd HH:mm")
    private static let moodleDateTimeFormatter = posixFormatter("yyyy/MM/dd HH:mm")

    private static func posixFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = AppConstants.taipeiTimeZone
        return formatter
    }

    var weekdayIndex: Int {
        let weekday = Self.scheduleCalendar.component(.weekday, from: self)
        return (weekday + 5) % 7
    }

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
        f.timeZone = AppConstants.taipeiTimeZone
        return f
    }()

    private static let absoluteFormatterNoSeconds: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = AppConstants.taipeiTimeZone
        return f
    }()

    var absoluteTimeString: String {
        let seconds = Self.scheduleCalendar.component(.second, from: self)
        if seconds == 0 {
            return Self.absoluteFormatterNoSeconds.string(from: self)
        }
        return Self.absoluteFormatter.string(from: self)
    }

    var absoluteMinuteString: String {
        Self.absoluteFormatterNoSeconds.string(from: self)
    }

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
