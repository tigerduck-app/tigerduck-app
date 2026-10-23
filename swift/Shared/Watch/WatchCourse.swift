import Foundation

public nonisolated struct WatchCourse: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let courseNo: String
    public let name: String
    public let teacher: String
    public let classroom: String
    public let colorHex: String
    public let weekday: Int
    public let startHHmm: String
    public let endHHmm: String
    public let periodLabel: String
    public let skippedDates: Set<String>?

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
        periodLabel: String,
        skippedDates: Set<String>? = nil
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
        self.skippedDates = skippedDates
    }
}
