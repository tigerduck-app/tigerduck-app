import Foundation
import TigerDuckCore

public nonisolated enum NextClassResolver {

    public struct Result: Equatable {
        public let current: WatchCourse?
        public let next: WatchCourse?
        public let nextDay: Day
        public let currentSpan: ClosedRange<Date>?
    }

    public typealias Day = ClassDay

    public static func resolve(courses: [WatchCourse], now: Date, quietDays: Set<String> = []) -> Result {
        let schedule = WatchSchedule(courses: courses, quietDays: quietDays)
        let found = schedule.timeline.nowAndNext(at: now)
        return Result(
            current: found.current.map(schedule.course), next: found.next.map(schedule.course), nextDay: found.day,
            currentSpan: found.current.map { $0.start...$0.end }
        )
    }

    public static func todaysClasses(courses: [WatchCourse], now: Date, quietDays: Set<String>) -> [WatchCourse] {
        let schedule = WatchSchedule(courses: courses, quietDays: quietDays)
        return schedule.timeline.classes(on: now).filter { !$0.isCancelled }.map(schedule.course)
    }

    public static func boundaries(courses: [WatchCourse], after now: Date, days: Int, quietDays: Set<String>) -> [Date] {
        WatchSchedule(courses: courses, quietDays: quietDays).timeline.boundaries(after: now, days: days)
    }
}

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
