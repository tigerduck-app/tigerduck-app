import Foundation

/// A timetable's classes on each day, and which one is on now and which comes next. The app, the
/// widgets and the Watch each convert their own course data into `ClassMeeting`s.
public struct ClassTimeline: Sendable {
    public let meetings: [ClassMeeting]
    /// Taipei day keys (`yyyy-MM-dd`) with no classes; `QuietDayCalendar` works them out.
    public let quietDays: Set<String>

    /// How far ahead a look for the next class day goes.
    public static let lookAheadDays = 7

    public init(meetings: [ClassMeeting], quietDays: Set<String> = []) {
        self.meetings = meetings
        self.quietDays = quietDays
    }

    /// The day's classes earliest first, cancelled ones kept and marked: each meeting on the day's
    /// weekday not skipped that day, or the classes the school changed it into. A quiet day has none.
    public func classes(on date: Date) -> [ScheduledClass] {
        let key = TaipeiTime.dayKey(for: date)
        guard !quietDays.contains(key) else { return [] }
        let day = TaipeiTime.calendar.startOfDay(for: date)
        let weekday = Self.weekday(of: date)
        func instant(_ minutes: Int) -> Date { day.addingTimeInterval(TimeInterval(minutes * 60)) }
        var result: [ScheduledClass] = []
        for (index, meeting) in meetings.enumerated() where meeting.weekday == weekday && !meeting.skippedDays.contains(key) {
            let changed = meeting.changes.indices.filter { meeting.changes[$0].day == key }
            guard !changed.isEmpty else {
                result.append(ScheduledClass(
                    meeting: index, change: nil, periods: meeting.periods, start: instant(meeting.start),
                    end: instant(meeting.end), room: meeting.room, isCancelled: false
                ))
                continue
            }
            for changeIndex in changed {
                let change = meeting.changes[changeIndex]
                result.append(ScheduledClass(
                    meeting: index, change: changeIndex, periods: change.periods, start: instant(change.start),
                    end: instant(change.end), room: change.room, isCancelled: change.isCancelled
                ))
            }
        }
        return result.sorted { $0.start < $1.start }
    }

    /// The first class on at `time` and the class after it, the first other one of the day not yet
    /// over. With neither, the first class of the next day that has one, up to `lookAheadDays` on.
    public func nowAndNext(at time: Date) -> (current: ScheduledClass?, next: ScheduledClass?, day: ClassDay) {
        let today = classes(on: time).filter { !$0.isCancelled }
        let current = today.firstIndex { $0.start <= time && time < $0.end }
        let next = today.indices.first { $0 != current && today[$0].end > time }
        if current != nil || next != nil {
            return (current.map { today[$0] }, next.map { today[$0] }, .today)
        }
        for offset in 1...Self.lookAheadDays {
            guard let day = TaipeiTime.calendar.date(byAdding: .day, value: offset, to: time),
                  let first = classes(on: day).first(where: { !$0.isCancelled }) else { continue }
            return (nil, first, offset == 1 ? .tomorrow : .later(weekday: Self.weekday(of: day)))
        }
        return (nil, nil, .today)
    }

    /// The starts and ends after `time` of the classes held on `days` days from `time`'s day.
    public func boundaries(after time: Date, days: Int) -> [Date] {
        (0..<days).flatMap { offset -> [Date] in
            guard let day = TaipeiTime.calendar.date(byAdding: .day, value: offset, to: time) else { return [] }
            return classes(on: day).filter { !$0.isCancelled }.flatMap { [$0.start, $0.end] }
        }
        .filter { $0 > time }
    }
}

extension ClassTimeline {
    /// The classes on at `time`: begun and not yet over, or not past their end with `includingEnd`.
    public static func running<C: TimedClass>(at time: Date, in classes: [C], includingEnd: Bool = false) -> [C] {
        classes.filter { $0.start <= time && (includingEnd ? time <= $0.end : time < $0.end) }
    }

    /// The class that starts soonest after `time`, the first listed of several that start together.
    public static func next<C: TimedClass>(after time: Date, in classes: [C]) -> C? {
        classes.filter { $0.start > time }.min { $0.start < $1.start }
    }

    /// Where `time` falls among `classes`, which are sorted by start.
    public static func state<C: TimedClass>(at time: Date, in classes: [C], includingEnd: Bool = false) -> ClassState<C> {
        let active = running(at: time, in: classes, includingEnd: includingEnd)
        if !active.isEmpty { return .inClass(active) }
        let previous = classes.last { $0.end <= time }
        let next = classes.first { $0.start > time }
        if previous == nil, let next { return .beforeFirst(next: next) }
        if let previous, next == nil { return .afterLast(previous: previous) }
        return .between(previous: previous, next: next)
    }

    /// `periods` in `order`, unknown ones last, split into runs of consecutive periods. Each run is
    /// one meeting, and an unknown period is a meeting of its own.
    public static func runs(of periods: [String], order: [String]) -> [[String]] {
        let index = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var runs: [[String]] = []
        for period in periods.sorted(by: { (index[$0] ?? .max) < (index[$1] ?? .max) }) {
            if let last = runs.last?.last, let previous = index[last], let current = index[period], current == previous + 1 {
                runs[runs.count - 1].append(period)
            } else {
                runs.append([period])
            }
        }
        return runs
    }

    /// Minutes after midnight of an `HH:mm` time.
    public static func minutes(of hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
        return hour * 60 + minute
    }

    /// The Taipei weekday, 1 for Monday to 7 for Sunday.
    public static func weekday(of date: Date) -> Int {
        (TaipeiTime.calendar.component(.weekday, from: date) + 5) % 7 + 1
    }
}
