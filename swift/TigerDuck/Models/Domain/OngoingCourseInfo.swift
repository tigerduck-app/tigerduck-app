import Foundation

struct OngoingCourseInfo: Identifiable {
    let course: SDCourse
    let weekday: Int
    let firstPeriodId: String
    let periods: [String]
    let startMinute: Int
    let endMinute: Int

    var id: String { "\(course.courseNo)-\(weekday)-\(firstPeriodId)" }

    var classroom: String {
        course.classroom(weekday: weekday, periods: periods)
    }

    var formattedTimeRange: String {
        func hm(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }
        return "\(hm(startMinute)) - \(hm(endMinute))"
    }
}

extension Array where Element == SDCourse {
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
                   (startMin..<endMin).contains(minuteOfDay) {
                    results.append(
                        OngoingCourseInfo(
                            course: course,
                            weekday: weekday,
                            firstPeriodId: firstId,
                            periods: [String](periods[blockStart...blockEnd]),
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
