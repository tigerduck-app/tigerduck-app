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
    /// The school's changes to this course's meetings; a reader that predates them ignores the key.
    let changes: [SnapshotCourseChange]

    init(
        courseNo: String,
        displayName: String,
        classroom: String,
        schedule: [Int: [String]],
        colorHex: UInt32,
        skippedDates: Set<String> = [],
        classroomMap: [String: String] = [:],
        changes: [SnapshotCourseChange] = []
    ) {
        self.courseNo = courseNo
        self.displayName = displayName
        self.classroom = classroom
        self.schedule = schedule
        self.colorHex = colorHex
        self.skippedDates = skippedDates
        self.classroomMap = classroomMap
        self.changes = changes
    }

    func classroom(weekday: Int, periods: [String]) -> String {
        CourseBlockRoom.room(weekday: weekday, periods: periods, map: classroomMap, fallback: classroom)
    }

    /// The change to the meeting that starts with `firstPeriod` on the `yyyy-MM-dd` day.
    func change(on day: String, startingAt firstPeriod: String?) -> SnapshotCourseChange? {
        changes.first { $0.day == day && $0.periods.first == firstPeriod }
    }
}

/// One meeting as the school changed it on one day; nil fields keep the timetable's value.
nonisolated struct SnapshotCourseChange: Codable, Equatable, Hashable, Sendable {
    /// `yyyy-MM-dd`, Taipei time.
    let day: String
    let periods: [String]
    let cancelled: Bool
    let room: String?
    /// `HH:mm`, Taipei time.
    let start: String?
    let end: String?
}

nonisolated extension SnapshotCourse {
    private enum CodingKeys: String, CodingKey {
        case courseNo, displayName, classroom, schedule, colorHex, skippedDates, classroomMap, changes
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
            classroomMap: c.decodeIfPresent([String: String].self, forKey: .classroomMap) ?? [:],
            changes: c.decodeIfPresent([SnapshotCourseChange].self, forKey: .changes) ?? []
        )
    }
}

nonisolated struct PeriodTime: Codable, Equatable, Hashable, Sendable {
    let start: String
    let end: String
}
