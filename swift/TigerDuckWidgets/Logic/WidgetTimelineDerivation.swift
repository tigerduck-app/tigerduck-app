import Foundation
import TigerDuckCore

enum WidgetDerivedState: nonisolated Equatable, Sendable {
    case signInRequired
    case ongoing([OngoingInfo])
    case nextToday(NextInfo)
    case tomorrowFirst(NextInfo)
    case noMoreClasses

    struct OngoingInfo: nonisolated Equatable, Sendable {
        let course: SnapshotCourse
        let startTime: String
        let endTime: String
        let periodRange: String
        let progress: Double
        let classroom: String
        var change: SnapshotCourseChange? = nil
    }

    struct NextInfo: nonisolated Equatable, Sendable {
        let course: SnapshotCourse
        let startTime: String
        let periodRange: String
        let day: Day
        let classroom: String
        var change: SnapshotCourseChange? = nil
    }

    typealias Day = ClassDay
}

extension ClassDay {
    func headline(in bundle: Bundle = .main) -> String {
        switch self {
        case .today: return String(localized: "widget_next_class", bundle: bundle)
        case .tomorrow: return String(localized: "widget_tomorrow", bundle: bundle)
        case .later(let weekday): return Self.caption(of: weekday, in: bundle)
        }
    }

    func inlineCaption(_ trailing: String, in bundle: Bundle = .main) -> String {
        switch self {
        case .later(let weekday):
            return "\(Self.caption(of: weekday, in: bundle)) \(trailing)"
        case .today, .tomorrow:
            return String.localizedStringWithFormat(
                String(localized: "widget_tomorrow_time", bundle: bundle), trailing)
        }
    }

    private static func caption(of weekday: Int, in bundle: Bundle) -> String {
        switch weekday {
        case 1: return String(localized: "weekday_mon_caption", bundle: bundle)
        case 2: return String(localized: "weekday_tue_caption", bundle: bundle)
        case 3: return String(localized: "weekday_wed_caption", bundle: bundle)
        case 4: return String(localized: "weekday_thu_caption", bundle: bundle)
        case 5: return String(localized: "weekday_fri_caption", bundle: bundle)
        case 6: return String(localized: "weekday_sat_caption", bundle: bundle)
        default: return String(localized: "weekday_sun_caption", bundle: bundle)
        }
    }
}

/// The snapshot as `ClassTimeline` meetings, each with the course and the changes it came from.
struct WidgetSchedule {
    let snapshot: WidgetSnapshot
    let timeline: ClassTimeline
    private let sources: [(course: Int, changes: [SnapshotCourseChange])]

    init(_ snapshot: WidgetSnapshot) {
        func minutes(_ changed: String?, _ period: String, _ time: KeyPath<PeriodTime, String>) -> Int? {
            (changed ?? snapshot.periodTimes[period]?[keyPath: time]).flatMap(ClassTimeline.minutes(of:))
        }
        var meetings: [ClassMeeting] = []
        var sources: [(course: Int, changes: [SnapshotCourseChange])] = []
        for (index, course) in snapshot.courses.enumerated() {
            for weekday in course.schedule.keys.sorted() {
                for run in ClassTimeline.runs(of: course.schedule[weekday] ?? [], order: snapshot.periodOrder) {
                    guard let start = minutes(nil, run[0], \.start), let end = minutes(nil, run[run.count - 1], \.end) else { continue }
                    let changes = course.changes.compactMap { change -> (SnapshotCourseChange, ClassChange)? in
                        guard let first = change.periods.first, let last = change.periods.last, run.contains(first),
                              let start = minutes(change.start, first, \.start),
                              let end = minutes(change.end, last, \.end) else { return nil }
                        let room = change.room ?? course.classroom(weekday: weekday, periods: change.periods)
                        return (change, ClassChange(
                            day: change.day, periods: change.periods, start: start, end: end, room: room,
                            isCancelled: change.cancelled
                        ))
                    }
                    meetings.append(ClassMeeting(
                        courseKey: course.courseNo, weekday: weekday, periods: run, start: start, end: end,
                        room: course.classroom(weekday: weekday, periods: run), skippedDays: course.skippedDates,
                        changes: changes.map(\.1)
                    ))
                    sources.append((index, changes.map(\.0)))
                }
            }
        }
        self.snapshot = snapshot
        self.timeline = ClassTimeline(meetings: meetings, quietDays: Set(snapshot.quietDayKeys ?? []))
        self.sources = sources
    }

    /// The index in the snapshot's `courses` of the course that holds `item`.
    func courseIndex(of item: ScheduledClass) -> Int { sources[item.meeting].course }

    func row(_ item: ScheduledClass) -> WidgetTimelineDerivation.TodayRow {
        let change = item.change.map { sources[item.meeting].changes[$0] }
        return .init(
            course: snapshot.courses[courseIndex(of: item)],
            periods: item.periods,
            startTime: change?.start ?? snapshot.periodTimes[item.periods[0]]?.start ?? "",
            endTime: change?.end ?? snapshot.periodTimes[item.periods[item.periods.count - 1]]?.end ?? "",
            classroom: item.room,
            change: change
        )
    }
}

enum WidgetTimelineDerivation {
    static func derive(snapshot: WidgetSnapshot, at date: Date) -> WidgetDerivedState {
        guard snapshot.isLoggedIn else { return .signInRequired }
        guard !snapshot.courses.isEmpty else { return .noMoreClasses }

        let schedule = WidgetSchedule(snapshot)
        let today = schedule.timeline.classes(on: date).filter { !$0.isCancelled }
        // One card per course, in the snapshot's course order.
        var seen = Set<Int>()
        let ongoing = ClassTimeline.running(at: date, in: today)
            .filter { seen.insert(schedule.courseIndex(of: $0)).inserted }
            .sorted { schedule.courseIndex(of: $0) < schedule.courseIndex(of: $1) }
        if !ongoing.isEmpty {
            return .ongoing(ongoing.map { ongoingInfo(schedule.row($0), at: date) })
        }

        let found = schedule.timeline.nowAndNext(at: date)
        guard let next = found.next else { return .noMoreClasses }
        let row = schedule.row(next)
        let info = WidgetDerivedState.NextInfo(
            course: row.course,
            startTime: row.startTime,
            periodRange: row.periods[0],
            day: found.day,
            classroom: row.classroom,
            change: row.change
        )
        return found.day == .today ? .nextToday(info) : .tomorrowFirst(info)
    }

    private static func ongoingInfo(_ row: TodayRow, at date: Date) -> WidgetDerivedState.OngoingInfo {
        let nowMin = minuteOfDay(date)
        let firstStart = ClassTimeline.minutes(of: row.startTime) ?? nowMin
        let lastEnd = ClassTimeline.minutes(of: row.endTime) ?? nowMin
        let progress = lastEnd > firstStart ? Double(nowMin - firstStart) / Double(lastEnd - firstStart) : 0
        return .init(
            course: row.course,
            startTime: row.startTime,
            endTime: row.endTime,
            periodRange: row.periodRange,
            progress: progress.clamped(to: 0...1),
            classroom: row.classroom,
            change: row.change
        )
    }

    struct TodayRow: nonisolated Equatable, Identifiable, Sendable {
        let course: SnapshotCourse
        let periods: [String]
        let startTime: String
        let endTime: String
        let classroom: String
        var change: SnapshotCourseChange? = nil

        var id: String { "\(course.courseNo)-\(periods[0])" }
        var periodRange: String { periods.count > 1 ? "\(periods[0])–\(periods[periods.count - 1])" : periods[0] }
        var isCancelled: Bool { change?.cancelled == true }
    }

    /// Today's classes, cancelled ones included, by start and then by period.
    static func todayRows(snapshot: WidgetSnapshot, at date: Date) -> [TodayRow] {
        let schedule = WidgetSchedule(snapshot)
        let order = snapshot.periodOrder
        func key(_ row: TodayRow) -> (Int, Int) {
            (ClassTimeline.minutes(of: row.startTime) ?? .max, order.firstIndex(of: row.periods[0]) ?? .max)
        }
        return schedule.timeline.classes(on: date).map(schedule.row).sorted { key($0) < key($1) }
    }

    static func dateKey(for date: Date) -> String {
        return Self.dateKeyFormatter.string(from: date)
    }

    private static let dateKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TaipeiTime.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func minuteOfDay(_ date: Date) -> Int {
        let parts = TaipeiTime.calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

extension WidgetTimelineDerivation {
    /// The first Taipei midnight after `date`, when a widget with nothing to show asks again.
    /// A single entry with `.atEnd` would make WidgetKit reload it at once, over and over; the
    /// app reloads every timeline itself when it writes a snapshot.
    static func nextMidnight(after date: Date, calendar: Calendar = TaipeiTime.calendar) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: startOfDay)
            ?? startOfDay.addingTimeInterval(86_400)
    }

    static func entryDates(
        snapshot: WidgetSnapshot,
        after now: Date,
        calendar: Calendar = TaipeiTime.calendar
    ) -> [Date] {
        var result: Set<Date> = [now]
        let weekday = ClassTimeline.weekday(of: now)
        let dayStart = calendar.startOfDay(for: now)

        let todayKey = dateKey(for: now)
        for course in snapshot.courses {
            for change in course.changes where change.day == todayKey {
                for time in [change.start, change.end].compactMap({ $0.flatMap(ClassTimeline.minutes(of:)) }) {
                    if let date = calendar.date(byAdding: .minute, value: time, to: dayStart), date > now {
                        result.insert(date)
                    }
                }
            }
            guard let periods = course.schedule[weekday] else { continue }
            for periodId in periods {
                guard let pt = snapshot.periodTimes[periodId] else { continue }
                if let start = ClassTimeline.minutes(of: pt.start),
                   let date = calendar.date(byAdding: .minute, value: start, to: dayStart),
                   date > now {
                    result.insert(date)
                }
                if let end = ClassTimeline.minutes(of: pt.end),
                   let date = calendar.date(byAdding: .minute, value: end, to: dayStart),
                   date > now {
                    result.insert(date)
                }
            }
        }

        if let midnight = calendar.date(byAdding: .day, value: 1, to: dayStart) {
            result.insert(midnight)
        }

        return result.sorted()
    }
}
