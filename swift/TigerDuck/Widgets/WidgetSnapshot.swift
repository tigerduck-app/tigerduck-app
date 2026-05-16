import Foundation

struct WidgetSnapshot: Codable, Equatable, Hashable, Sendable {
    let version: Int
    let generatedAt: Date
    let isLoggedIn: Bool
    let accentColorHex: UInt32
    let courses: [SnapshotCourse]
    let periodTimes: [String: PeriodTime]
    let periodOrder: [String]
    let activeWeekdays: [Int]
    let activePeriodIds: [String]

    static let currentVersion = 1
    static let storeKey = "Widget-snapshot-v1"
    static let appGroupIdentifier = "group.org.ntust.app.TigerDuck1"
}

struct SnapshotCourse: Codable, Equatable, Hashable, Sendable {
    let courseNo: String
    let displayName: String
    let classroom: String
    let schedule: [Int: [String]]
    let colorHex: UInt32
    /// `yyyy-MM-dd` keys (Gregorian / en_US_POSIX / device time zone) matching
    /// `SDCourse.isoFormatter`. The widget filters scheduled periods through
    /// this set so toggling skip in the app removes the class from "ongoing"
    /// and "next" without waiting for a data refresh.
    let skippedDates: Set<String>

    init(
        courseNo: String,
        displayName: String,
        classroom: String,
        schedule: [Int: [String]],
        colorHex: UInt32,
        skippedDates: Set<String> = []
    ) {
        self.courseNo = courseNo
        self.displayName = displayName
        self.classroom = classroom
        self.schedule = schedule
        self.colorHex = colorHex
        self.skippedDates = skippedDates
    }
}

extension SnapshotCourse {
    private enum CodingKeys: String, CodingKey {
        case courseNo, displayName, classroom, schedule, colorHex, skippedDates
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            courseNo: c.decode(String.self, forKey: .courseNo),
            displayName: c.decode(String.self, forKey: .displayName),
            classroom: c.decode(String.self, forKey: .classroom),
            schedule: c.decode([Int: [String]].self, forKey: .schedule),
            colorHex: c.decode(UInt32.self, forKey: .colorHex),
            skippedDates: c.decodeIfPresent(Set<String>.self, forKey: .skippedDates) ?? []
        )
    }
}

struct PeriodTime: Codable, Equatable, Hashable, Sendable {
    let start: String   // "HH:mm"
    let end: String     // "HH:mm"
}
