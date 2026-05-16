import Foundation

/// One concrete weekly session of a course on the watch. A class that meets
/// twice a week is serialised as two `WatchCourse` rows — the watch never has
/// to expand multi-weekday schedules itself.
///
/// Wire-format DTO. Decoupled from `SDCourse` so phone-side schema churn does
/// not ripple to the watch unless this struct's fields change.
public struct WatchCourse: Codable, Hashable, Identifiable, Sendable {
    public let id: String         // "<courseNo>-<weekday>-<firstPeriod>"
    public let courseNo: String
    public let name: String
    public let teacher: String
    public let classroom: String
    public let colorHex: String   // "#RRGGBB"
    public let weekday: Int       // 1 = Mon … 7 = Sun (ISO)
    public let startHHmm: String  // first-period start, e.g. "10:20"
    public let endHHmm: String    // last-period end, e.g. "11:10"
    public let periodLabel: String // human-readable e.g. "3-4" or "A"

    public init(
        id: String,
        courseNo: String,
        name: String,
        teacher: String,
        classroom: String,
        colorHex: String,
        weekday: Int,
        startHHmm: String,
        endHHmm: String,
        periodLabel: String
    ) {
        self.id = id
        self.courseNo = courseNo
        self.name = name
        self.teacher = teacher
        self.classroom = classroom
        self.colorHex = colorHex
        self.weekday = weekday
        self.startHHmm = startHHmm
        self.endHHmm = endHHmm
        self.periodLabel = periodLabel
    }
}
