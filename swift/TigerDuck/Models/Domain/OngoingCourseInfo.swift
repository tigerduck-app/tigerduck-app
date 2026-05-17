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
    /// `AppConstants.Periods.chronologicalOrder`. Only the first running
    /// block per course is returned.
    func ongoingCourses(weekday: Int, minuteOfDay: Int) -> [OngoingCourseInfo] {
        var results: [OngoingCourseInfo] = []
        for course in self {
            guard let raw = course.schedule[weekday], !raw.isEmpty else { continue }
            let periods = raw.sortedByPeriodOrder()
            var blockStart = 0
            while blockStart < periods.count {
                var blockEnd = blockStart
                while blockEnd + 1 < periods.count,
                      periodOrder(periods[blockEnd + 1]) == periodOrder(periods[blockEnd]) + 1 {
                    blockEnd += 1
                }
                let firstId = periods[blockStart]
                let lastId = periods[blockEnd]
                if let startMin = parseHm(AppConstants.PeriodTimes.mapping[firstId]?.start),
                   let endMin = parseHm(AppConstants.PeriodTimes.mapping[lastId]?.end),
                   (startMin...endMin).contains(minuteOfDay) {
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

private func parseHm(_ hhmm: String?) -> Int? {
    guard let hhmm else { return nil }
    let parts = hhmm.split(separator: ":")
    guard parts.count == 2,
          let h = Int(parts[0]),
          let m = Int(parts[1]) else { return nil }
    return h * 60 + m
}
