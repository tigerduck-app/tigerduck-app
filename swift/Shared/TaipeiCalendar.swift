import Foundation

public nonisolated enum SharedTaipei {
    public static let timeZone: TimeZone = TimeZone(identifier: "Asia/Taipei") ?? .current

    public static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        return c
    }()

    public static func dayKey(for date: Date) -> String {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }
}
