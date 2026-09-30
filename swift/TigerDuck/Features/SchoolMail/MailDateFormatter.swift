#if os(iOS)
import Foundation

/// Mail dates in Taipei time. The list shows `HH:mm` for today and `M/d` otherwise — the one
/// deliberate difference from the bulletin list, because the time of day matters for mail.
@MainActor
enum MailDateFormatter {
    static func listString(for date: Date, now: Date = Date()) -> String {
        AppConstants.taipeiCalendar.isDate(date, inSameDayAs: now) ? date.timeString : date.shortDateString
    }

    static func detailString(for date: Date) -> String {
        "\(date.fullDateString) \(date.timeString)"
    }
}
#endif
