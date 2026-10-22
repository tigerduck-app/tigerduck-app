import Foundation

nonisolated struct WidgetSnapshot: Codable, Equatable, Hashable, Sendable {
    let version: Int
    var generatedAt: Date
    let isLoggedIn: Bool
    let accentColorHex: UInt32
    let courses: [SnapshotCourse]
    let periodTimes: [String: PeriodTime]
    let periodOrder: [String]
    let activeWeekdays: [Int]
    let activePeriodIds: [String]
    var quietDayKeys: [String]? = nil

    static let currentVersion = 1
    static let storeKey = "Widget-snapshot-v1"
    static let appGroupIdentifier = "group.org.ntust.app.TigerDuck"
}

nonisolated struct SnapshotCourse: Codable, Equatable, Hashable, Sendable {
    let courseNo: String
    let displayName: String
    let classroom: String
    let schedule: [Int: [String]]
    let colorHex: UInt32
    let skippedDates: Set<String>
    let classroomMap: [String: String]

    init(
        courseNo: String,
        displayName: String,
        classroom: String,
        schedule: [Int: [String]],
        colorHex: UInt32,
        skippedDates: Set<String> = [],
        classroomMap: [String: String] = [:]
    ) {
        self.courseNo = courseNo
        self.displayName = displayName
        self.classroom = classroom
        self.schedule = schedule
        self.colorHex = colorHex
        self.skippedDates = skippedDates
        self.classroomMap = classroomMap
    }

    func classroom(weekday: Int, periods: [String]) -> String {
        CourseBlockRoom.room(weekday: weekday, periods: periods, map: classroomMap, fallback: classroom)
    }
}

nonisolated extension SnapshotCourse {
    private enum CodingKeys: String, CodingKey {
        case courseNo, displayName, classroom, schedule, colorHex, skippedDates, classroomMap
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            courseNo: c.decode(String.self, forKey: .courseNo),
            displayName: c.decode(String.self, forKey: .displayName),
            classroom: c.decode(String.self, forKey: .classroom),
            schedule: c.decode([Int: [String]].self, forKey: .schedule),
            colorHex: c.decode(UInt32.self, forKey: .colorHex),
            skippedDates: c.decodeIfPresent(Set<String>.self, forKey: .skippedDates) ?? [],
            classroomMap: c.decodeIfPresent([String: String].self, forKey: .classroomMap) ?? [:]
        )
    }
}

nonisolated struct PeriodTime: Codable, Equatable, Hashable, Sendable {
    let start: String
    let end: String
}
