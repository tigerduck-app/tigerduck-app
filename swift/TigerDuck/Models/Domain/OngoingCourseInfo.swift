import Foundation

/// One currently-running course block. Mirrors the Android
/// `OngoingCourseInfo` payload so the iOS "Current class" card has the
/// same data shape (start/end minutes are minutes-of-day under Taipei
/// time, so the progress bar can be computed without re-parsing
/// "HH:mm").
struct OngoingCourseInfo: Identifiable {
    let course: SDCourse
    let weekday: Int
    let firstPeriodId: String
    /// Block start in minutes-of-day (Taipei).
    let startMinute: Int
    /// Block end in minutes-of-day (Taipei).
    let endMinute: Int

    var id: String { "\(course.courseNo)-\(weekday)-\(firstPeriodId)" }
}

extension Array where Element == SDCourse {
    /// Returns the contiguous-period block of each course that is
    /// currently running at the given `weekday` / `minuteOfDay`. Matches
    /// the Android shared `computeOngoingCourses` so iOS and Android
    /// surface the same "Current class" set.
    ///
    /// Periods are considered contiguous when adjacent in
    /// `AppConstants.Periods.chronologicalOrder` AND the prior period's
    /// end time equals the next period's start time. Most periods have a
    /// real break between them (e.g. P1 ends 09:00, P2 starts 09:10), so
    /// without the touch-check we'd report a course as ongoing through
    /// the break. Only the first running block per course is returned.
    func ongoingCourses(weekday: Int, minuteOfDay: Int) -> [OngoingCourseInfo] {
        var results: [OngoingCourseInfo] = []
        for course in self {
            guard let raw = course.schedule[weekday], !raw.isEmpty else { continue }
            let periods = raw.sortedByPeriodOrder()
            var blockStart = 0
            while blockStart < periods.count {
                var blockEnd = blockStart
                while blockEnd + 1 < periods.count,
                      periodOrder(periods[blockEnd + 1]) == periodOrder(periods[blockEnd]) + 1,
                      periodsTouch(periods[blockEnd], periods[blockEnd + 1]) {
                    blockEnd += 1
                }
                let firstId = periods[blockStart]
                let lastId = periods[blockEnd]
                if let startMin = parseHm(AppConstants.PeriodTimes.mapping[firstId]?.start),
                   let endMin = parseHm(AppConstants.PeriodTimes.mapping[lastId]?.end),
                   (startMin..<endMin).contains(minuteOfDay) {
                    results.append(
                        OngoingCourseInfo(
                            course: course,
                            weekday: weekday,
                            firstPeriodId: firstId,
                            startMinute: startMin,
                            endMinute: endMin
                        )
                    )
                    break
                }
                blockStart = blockEnd + 1
            }
        }
        return results
    }
}

private func periodOrder(_ periodId: String) -> Int {
    AppConstants.Periods.chronologicalOrder.firstIndex(of: periodId) ?? Int.max
}

/// True when `a` ends at the exact minute `b` starts (no break between
/// them). Used to keep a course's running block from spanning a break.
private func periodsTouch(_ a: String, _ b: String) -> Bool {
    guard let aEnd = parseHm(AppConstants.PeriodTimes.mapping[a]?.end),
          let bStart = parseHm(AppConstants.PeriodTimes.mapping[b]?.start)
    else { return false }
    return aEnd == bStart
}

private func parseHm(_ hhmm: String?) -> Int? {
    guard let hhmm else { return nil }
    let parts = hhmm.split(separator: ":")
    guard parts.count == 2,
          let h = Int(parts[0]),
          let m = Int(parts[1]) else { return nil }
    return h * 60 + m
}
