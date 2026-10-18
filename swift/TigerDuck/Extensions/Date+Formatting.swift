import Foundation

extension Date {
    /// Gregorian + Asia/Taipei calendar pinned for every schedule-math
    /// helper below. NTUST's class table, semester boundaries, and ICS
    /// feeds are gregorian — using `Calendar.current` would shift
    /// month/day arithmetic on a device set to ROC or Buddhist calendar
    /// (already proven by `SDCourse.isoFormatter` pinning the same way).
    /// Aliased onto `AppConstants.taipeiCalendar` so app code has one
    /// canonical handle to the Taiwan-pinned calendar.
    static let scheduleCalendar: Calendar = AppConstants.taipeiCalendar

    var shortDateString: String {
        var style = Date.FormatStyle.dateTime.month(.defaultDigits).day()
        style.timeZone = AppConstants.taipeiTimeZone
        return formatted(style)
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

    /// A Moodle list's time stamp: `HH:mm` today, else ``moodleDateString(now:)``. Zero-padded,
    /// so the stamps of a list line up.
    func moodleListDateString(now: Date = AppClock.now()) -> String {
        if isSameDay(as: now) { return Self.moodleTimeFormatter.string(from: self) }
        return moodleDateString(now: now)
    }

    /// A Moodle date: `MM/dd` this year, `yyyy/MM/dd` in any other.
    func moodleDateString(now: Date = AppClock.now()) -> String {
        let calendar = Self.scheduleCalendar
        let thisYear = calendar.component(.year, from: self) == calendar.component(.year, from: now)
        return (thisYear ? Self.moodleMonthDayFormatter : Self.fullDateFormatter).string(from: self)
    }

    /// `yyyy/MM/dd HH:mm`, for the masthead of a Moodle post.
    var moodleDateTimeString: String {
        Self.moodleDateTimeFormatter.string(from: self)
    }

    /// Use the school calendar's year so the device's time zone cannot change a post's label.
    func moodlePostDateString(now: Date = AppClock.now()) -> String {
        let calendar = Self.scheduleCalendar
        let thisYear = calendar.component(.year, from: self) == calendar.component(.year, from: now)
        return (thisYear ? Self.moodleMonthDayTimeFormatter : Self.moodleDateTimeFormatter).string(from: self)
    }

    private static let moodleTimeFormatter = posixFormatter("HH:mm")
    private static let moodleMonthDayFormatter = posixFormatter("MM/dd")
    private static let moodleMonthDayTimeFormatter = posixFormatter("MM/dd HH:mm")
    private static let moodleDateTimeFormatter = posixFormatter("yyyy/MM/dd HH:mm")

    /// Gregorian, POSIX and Taipei, as ``fullDateString`` pins them.
    private static func posixFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = AppConstants.taipeiTimeZone
        return formatter
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

    /// Absolute time. Drops the `:ss` component when seconds are zero
    /// (Moodle deadlines are typically minute-aligned), so the common case
    /// reads as "3/24 23:59" instead of the noisier "3/24 23:59:00".
    var absoluteTimeString: String {
        let seconds = Self.scheduleCalendar.component(.second, from: self)
        if seconds == 0 {
            return Self.absoluteFormatterNoSeconds.string(from: self)
        }
        return Self.absoluteFormatter.string(from: self)
    }

    /// ``absoluteTimeString`` that never shows seconds, for a time read to the minute.
    var absoluteMinuteString: String {
        Self.absoluteFormatterNoSeconds.string(from: self)
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
