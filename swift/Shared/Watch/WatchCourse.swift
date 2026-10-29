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
    /// The school's changes to this meeting, by Taipei day key (`yyyy-MM-dd`).
    public let changes: [String: WatchCourseChange]?
    /// The change ``on(_:)`` applied, so a view can mark the values it replaced.
    public private(set) var dayChange: WatchCourseChange?

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
        changes: [String: WatchCourseChange]? = nil
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
    }

    /// This meeting as it runs on a day: nil when the school cancelled it, otherwise with the
    /// day's changed time and room in place.
    public func on(_ dayKey: String) -> WatchCourse? {
        guard let change = changes?[dayKey] else { return self }
        guard !change.cancelled else { return nil }
        var shown = WatchCourse(
            id: id, courseNo: courseNo, name: name, teacher: teacher,
            classroom: change.room ?? classroom, colorHex: colorHex, weekday: weekday,
            startHHmm: change.start ?? startHHmm, endHHmm: change.end ?? endHHmm,
            periodLabel: periodLabel, skippedDates: skippedDates, changes: changes
        )
        shown.dayChange = change
        return shown
    }
}

/// One day's change to a meeting; nil fields keep the timetable's value.
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
