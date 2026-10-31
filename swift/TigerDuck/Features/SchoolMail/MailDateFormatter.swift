#if os(iOS)
import Foundation
import TigerDuckCore

@MainActor
enum MailDateFormatter {
    static func listString(for date: Date, now: Date = Date()) -> String {
        TaipeiTime.calendar.isDate(date, inSameDayAs: now) ? date.timeString : date.shortDateString
    }

    static func detailString(for date: Date) -> String {
        "\(date.fullDateString) \(date.timeString)"
    }
}
#endif
