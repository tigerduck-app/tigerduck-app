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
    /// The classes this meeting holds on each day the school changed it, by Taipei day key
    /// (`yyyy-MM-dd`), with their changed times and rooms in place.
    public let changes: [String: [WatchCourse]]?
    /// What the school changed in this class, so a view can mark the values it replaced.
    public let dayChange: WatchCourseChange?

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
        skippedDates: Set<String>? = nil,
        changes: [String: [WatchCourse]]? = nil,
        dayChange: WatchCourseChange? = nil
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
        self.changes = changes
        self.dayChange = dayChange
    }

    /// The classes this meeting holds on a day, leaving out the ones the school cancelled.
    public func on(_ dayKey: String) -> [WatchCourse] {
        guard let classes = changes?[dayKey] else { return [self] }
        return classes.filter { $0.dayChange?.cancelled != true }
    }
}

/// One day's change to a class; nil fields keep the timetable's value.
public nonisolated struct WatchCourseChange: Codable, Hashable, Sendable {
    public let cancelled: Bool
    public let room: String?
    /// `HH:mm`, Taipei time.
    public let start: String?
    public let end: String?

    public init(cancelled: Bool, room: String? = nil, start: String? = nil, end: String? = nil) {
        self.cancelled = cancelled
        self.room = room
        self.start = start
        self.end = end
    }
}
