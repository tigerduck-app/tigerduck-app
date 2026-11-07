import Foundation
import TigerDuckCore

enum EmptyClassroomDayText {
    static func label(_ day: Date, today: Date) -> String {
        let calendar = TaipeiTime.calendar
        let date = date(day)
        if calendar.isDate(day, inSameDayAs: today) {
            return "\(String(localized: "calendar_today")) \(date)"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
           calendar.isDate(day, inSameDayAs: tomorrow) {
            return "\(String(localized: "widget_tomorrow")) \(date)"
        }
        return date
    }

    static func date(_ day: Date) -> String {
        var symbols = Calendar(identifier: .gregorian)
        symbols.locale = .autoupdatingCurrent
        let narrow = symbols.veryShortWeekdaySymbols
        var style = Date.FormatStyle.dateTime.month(.defaultDigits).day()
            .weekday(Set(narrow).count == narrow.count ? .narrow : .abbreviated)
        style.timeZone = TaipeiTime.timeZone
        style.calendar = Calendar(identifier: .gregorian)
        return day.formatted(style)
    }

    static func timeRange(of period: Int) -> String {
        guard let range = EmptyClassroomSchedule.timeRange(of: period) else { return "" }
        return TimeRange.text(range.start, range.end)
    }

    static func spokenTimeRange(of period: Int) -> String {
        guard let range = EmptyClassroomSchedule.timeRange(of: period) else { return "" }
        return TimeRange.spoken(range.start, range.end)
    }
}
