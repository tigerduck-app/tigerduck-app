import Foundation
import TigerDuckCore

public nonisolated enum NextClassResolver {

    public struct Result: Equatable {
        public let current: WatchCourse?
        public let next: WatchCourse?
        public let nextDay: Day
    }

    public typealias Day = ClassDay

    public static func resolve(courses: [WatchCourse], now: Date, quietDays: Set<String> = []) -> Result {
        let schedule = WatchSchedule(courses: courses, quietDays: quietDays)
        let found = schedule.timeline.nowAndNext(at: now)
        return Result(current: found.current.map(schedule.course), next: found.next.map(schedule.course), nextDay: found.day)
    }

    public static func todaysClasses(courses: [WatchCourse], now: Date, quietDays: Set<String>) -> [WatchCourse] {
        let schedule = WatchSchedule(courses: courses, quietDays: quietDays)
        return schedule.timeline.classes(on: now).filter { !$0.isCancelled }.map(schedule.course)
    }

    /// The starts and ends after `now` of the classes held today and on the next `days - 1` days.
    public static func boundaries(courses: [WatchCourse], after now: Date, days: Int, quietDays: Set<String>) -> [Date] {
        WatchSchedule(courses: courses, quietDays: quietDays).timeline.boundaries(after: now, days: days)
    }
}

/// The phone's meetings as `ClassTimeline` meetings, each with the class it came from.
private nonisolated struct WatchSchedule {
    let timeline: ClassTimeline
    private let sources: [(meeting: WatchCourse, changes: [(day: String, held: WatchCourse)])]

    init(courses: [WatchCourse], quietDays: Set<String>) {
        func minutes(_ hhmm: String) -> Int { ClassTimeline.minutes(of: hhmm) ?? 0 }
        let sources = courses.map { course in
            let changes = (course.changes ?? [:]).sorted { $0.key < $1.key }.flatMap { day, held in
                held.map { (day: day, held: $0) }
            }
            return (meeting: course, changes: changes)
        }
        self.sources = sources
        timeline = ClassTimeline(meetings: sources.map { course, changes in
            ClassMeeting(
                courseKey: course.courseNo, weekday: course.weekday, periods: [course.periodLabel],
                start: minutes(course.startHHmm), end: minutes(course.endHHmm), room: course.classroom,
                skippedDays: course.skippedDates ?? [],
                changes: changes.map { day, held in
                    ClassChange(
                        day: day, periods: [held.periodLabel], start: minutes(held.startHHmm), end: minutes(held.endHHmm),
                        room: held.classroom, isCancelled: held.dayChange?.cancelled == true
                    )
                }
            )
        }, quietDays: quietDays)
    }

    func course(_ item: ScheduledClass) -> WatchCourse {
        item.change.map { sources[item.meeting].changes[$0].held } ?? sources[item.meeting].meeting
    }
}

nonisolated extension ClassDay {
    public func headline(in language: WatchLanguage) -> String {
        switch self {
        case .today: return language.string("watch_next")
        case .tomorrow: return language.string("widget_tomorrow")
        case .later(let weekday): return Self.caption(of: weekday, in: language)
        }
    }

    public func inlineCaption(_ time: String, in language: WatchLanguage) -> String {
        switch self {
        case .today:
            return time
        case .tomorrow:
            return language.format("widget_tomorrow_time", time)
        case .later(let weekday):
            return "\(Self.caption(of: weekday, in: language)) \(time)"
        }
    }

    private static func caption(of weekday: Int, in language: WatchLanguage) -> String {
        switch weekday {
        case 1: return language.string("weekday_mon_caption")
        case 2: return language.string("weekday_tue_caption")
        case 3: return language.string("weekday_wed_caption")
        case 4: return language.string("weekday_thu_caption")
        case 5: return language.string("weekday_fri_caption")
        case 6: return language.string("weekday_sat_caption")
        default: return language.string("weekday_sun_caption")
        }
    }
}
