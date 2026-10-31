import Foundation

/// A class with a start and an end, which `ClassTimeline`'s rules pick from.
public protocol TimedClass {
    var start: Date { get }
    var end: Date { get }
}

extension TimedClass {
    /// Begun at `time` and not yet over, or not past its end with `includingEnd`.
    public func isOn(at time: Date, includingEnd: Bool = false) -> Bool {
        start <= time && (includingEnd ? time <= end : time < end)
    }
}

/// One meeting of the weekly timetable: a run of consecutive periods of a course on a weekday.
public struct ClassMeeting: Hashable, Sendable {
    public var courseKey: String
    /// 1 is Monday and 7 Sunday.
    public var weekday: Int
    public var periods: [String]
    /// Minutes after midnight, Taipei time.
    public var start: Int
    public var end: Int
    public var room: String
    /// Taipei day keys (`yyyy-MM-dd`) on which the user skips the course.
    public var skippedDays: Set<String>
    /// The school's changes: on a day listed here the meeting holds those classes instead.
    public var changes: [ClassChange]

    public init(
        courseKey: String, weekday: Int, periods: [String], start: Int, end: Int, room: String,
        skippedDays: Set<String> = [], changes: [ClassChange] = []
    ) {
        self.courseKey = courseKey
        self.weekday = weekday
        self.periods = periods
        self.start = start
        self.end = end
        self.room = room
        self.skippedDays = skippedDays
        self.changes = changes
    }
}

/// One class a changed meeting holds on one day, with its changed times and room in place.
public struct ClassChange: Hashable, Sendable {
    /// `yyyy-MM-dd`, Taipei time.
    public var day: String
    public var periods: [String]
    /// Minutes after midnight, Taipei time.
    public var start: Int
    public var end: Int
    public var room: String
    public var isCancelled: Bool

    public init(day: String, periods: [String], start: Int, end: Int, room: String, isCancelled: Bool = false) {
        self.day = day
        self.periods = periods
        self.start = start
        self.end = end
        self.room = room
        self.isCancelled = isCancelled
    }
}

/// A class on one day: a timetable meeting, or one of the classes the school changed it into.
public struct ScheduledClass: Hashable, Sendable, TimedClass {
    /// The meeting's index in the timeline's `meetings`.
    public let meeting: Int
    /// The index in that meeting's `changes` of the change that holds this class.
    public let change: Int?
    public let periods: [String]
    public let start: Date
    public let end: Date
    public let room: String
    public let isCancelled: Bool
}

/// The day a class falls on, counted from today.
public enum ClassDay: Hashable, Sendable {
    case today
    case tomorrow
    /// 1 is Monday and 7 Sunday.
    case later(weekday: Int)
}

public enum ClassState<Class> {
    case inClass([Class])
    case between(previous: Class?, next: Class?)
    case beforeFirst(next: Class)
    case afterLast(previous: Class)
}

extension ClassState: Equatable where Class: Equatable {}
extension ClassState: Sendable where Class: Sendable {}
