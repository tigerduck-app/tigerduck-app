import Foundation

/// The school's calendar and time zone. Day and class-time math runs in Taipei whatever zone the
/// device is set to, so a class is on the same day for a student abroad.
public enum TaipeiTime {
    public static let timeZone: TimeZone = TimeZone(identifier: "Asia/Taipei") ?? .current

    public static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }()

    /// The Taipei date as `yyyy-MM-dd`.
    public static func dayKey(for date: Date) -> String {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }
}
