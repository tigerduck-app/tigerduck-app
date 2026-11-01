import Foundation
import TigerDuckCore

struct CourseMeeting {
    let course: SDCourse
    let date: Date
    let dayKey: String
    let periods: [String]
    let start: Date
    let end: Date
    let timetableStart: Date
    let timetableEnd: Date
    let changes: [CourseChange]

    func isCancelled(_ period: String) -> Bool {
        changes.contains { $0.kind == .cancelled && $0.covers(period) }
    }

    func room(_ period: String) -> String? {
        changes.first { $0.kind == .room && $0.covers(period) }?.room
    }

    func slots() -> [CourseTimeSlot] {
        let fragments = fragments()
        return fragments.isEmpty ? [Self.merged([self])].compactMap { $0 } : fragments
    }

    func fragments() -> [CourseTimeSlot] {
        var runs: [[String]] = []
        for period in periods {
            if let last = runs.last?.last, isCancelled(last) == isCancelled(period), room(last) == room(period) {
                runs[runs.count - 1].append(period)
            } else {
                runs.append([period])
            }
        }
        let pieces = runs.enumerated().compactMap { index, run -> (run: [String], start: Date, end: Date, ownStart: Date, ownEnd: Date)? in
            guard let ownStart = Self.periodTime(run[0], end: false, on: date),
                  let ownEnd = Self.periodTime(run[run.count - 1], end: true, on: date) else { return nil }
            let pieceStart = index == 0 ? start : min(max(ownStart, start), end)
            let pieceEnd = index == runs.count - 1 ? end : min(max(ownEnd, start), end)
            return pieceStart < pieceEnd ? (run, pieceStart, pieceEnd, ownStart, ownEnd) : nil
        }
        return pieces.enumerated().map { index, piece in
            let fragmentStart = index == 0 ? start : piece.start
            let fragmentEnd = index == pieces.count - 1 ? end : piece.end
            return CourseTimeSlot(
                id: "\(course.courseNo)_\(dayKey)_\(piece.run[0])",
                course: course,
                start: fragmentStart,
                end: fragmentEnd,
                date: date,
                periods: piece.run,
                changes: changes.filter { $0.kind == .start || $0.kind == .end || piece.run.contains(where: $0.covers) },
                originalStart: fragmentStart == piece.ownStart ? nil : piece.ownStart,
                originalEnd: fragmentEnd == piece.ownEnd ? nil : piece.ownEnd
            )
        }
    }


    static func meetings(
        of course: SDCourse, weekday: Int? = nil, on date: Date, changes: CourseChanges
    ) -> [CourseMeeting] {
        let runs = ClassTimeline.runs(
            of: course.schedule[weekday ?? date.scheduleWeekday] ?? [], order: AppConstants.Periods.chronologicalOrder
        )
        let dayChanges = changes.changes(courseNo: course.courseNo, on: date)
        let dayKey = CourseTimeSlot.dayKeyFormatter.string(from: date)
        return runs.compactMap { run in
            guard let timetableStart = periodTime(run[0], end: false, on: date),
                  let timetableEnd = periodTime(run[run.count - 1], end: true, on: date) else { return nil }
            var applied = dayChanges.filter { run.contains(where: $0.covers) }
            var start = changedTime(.start, in: applied, on: date) ?? timetableStart
            var end = changedTime(.end, in: applied, on: date) ?? timetableEnd
            if end <= start {
                start = timetableStart
                end = timetableEnd
                applied.removeAll { $0.kind == .start || $0.kind == .end }
            }
            return CourseMeeting(
                course: course, date: date, dayKey: dayKey, periods: run, start: start, end: end,
                timetableStart: timetableStart, timetableEnd: timetableEnd, changes: applied
            )
        }
    }

    static func merged(_ meetings: [CourseMeeting]) -> CourseTimeSlot? {
        guard let first = meetings.first, let last = meetings.last else { return nil }
        let isCancelled = meetings.allSatisfy { meeting in meeting.periods.allSatisfy(meeting.isCancelled) }
        var merged: [CourseChange] = []
        for change in meetings.flatMap(\.changes)
        where (isCancelled || change.kind != .cancelled) && !merged.contains(where: { $0.id == change.id }) {
            merged.append(change)
        }
        return CourseTimeSlot(
            id: "\(first.course.courseNo)_\(first.dayKey)_\(first.periods[0])",
            course: first.course,
            start: first.start,
            end: last.end,
            date: first.date,
            periods: meetings.flatMap(\.periods),
            changes: merged,
            originalStart: first.start == first.timetableStart ? nil : first.timetableStart,
            originalEnd: last.end == last.timetableEnd ? nil : last.timetableEnd
        )
    }

    private static func periodTime(_ period: String, end: Bool, on date: Date) -> Date? {
        guard let times = AppConstants.PeriodTimes.mapping[period] else { return nil }
        return CourseTimeSlot.dateFromTimeString(end ? times.end : times.start, on: date)
    }

    private static func changedTime(_ kind: CourseChange.Kind, in changes: [CourseChange], on date: Date) -> Date? {
        guard let change = changes.first(where: { $0.kind == kind }),
              let time = kind == .start ? change.start : change.end
        else { return nil }
        return CourseTimeSlot.dateFromTimeString(time, on: date)
    }
}
