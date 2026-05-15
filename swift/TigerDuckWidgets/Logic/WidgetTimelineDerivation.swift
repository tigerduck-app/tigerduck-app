import Foundation

enum WidgetDerivedState: Equatable, Sendable {
    case signInRequired
    case ongoing([OngoingInfo])
    case nextToday(NextInfo)
    case tomorrowFirst(NextInfo)
    case noMoreClasses

    struct OngoingInfo: Equatable, Sendable {
        let course: SnapshotCourse
        let startTime: String              // "HH:mm"
        let endTime: String
        let periodRange: String            // "B" or "B–C"
        let progress: Double               // 0.0…1.0
    }

    struct NextInfo: Equatable, Sendable {
        let course: SnapshotCourse
        let startTime: String
        let periodRange: String
    }
}

enum WidgetTimelineDerivation {
    static func derive(snapshot: WidgetSnapshot, at date: Date) -> WidgetDerivedState {
        guard snapshot.isLoggedIn else { return .signInRequired }
        guard !snapshot.courses.isEmpty else { return .noMoreClasses }

        let weekday = weekdayFor(date)
        let nowMin = minuteOfDayFor(date)
        let order = snapshot.periodOrder

        // 1. Ongoing courses (any course whose any period contains nowMin)
        let ongoing = snapshot.courses.compactMap { course -> WidgetDerivedState.OngoingInfo? in
            guard let periods = course.schedule[weekday]?
                .sorted(by: { (order.firstIndex(of: $0) ?? .max) < (order.firstIndex(of: $1) ?? .max) }),
                  !periods.isEmpty else { return nil }
            let first = periods.first!
            let last = periods.last!
            guard let firstStart = parseHm(snapshot.periodTimes[first]?.start),
                  let lastEnd = parseHm(snapshot.periodTimes[last]?.end),
                  nowMin >= firstStart, nowMin < lastEnd else { return nil }
            let progress = lastEnd > firstStart
                ? Double(nowMin - firstStart) / Double(lastEnd - firstStart)
                : 0
            return .init(
                course: course,
                startTime: snapshot.periodTimes[first]?.start ?? "",
                endTime: snapshot.periodTimes[last]?.end ?? "",
                periodRange: periods.count > 1 ? "\(first)–\(last)" : first,
                progress: progress.clamped(to: 0...1)
            )
        }
        if !ongoing.isEmpty { return .ongoing(ongoing) }

        // 2. Next today (any course whose first period today starts in the future)
        let candidates = snapshot.courses.compactMap { course -> (SnapshotCourse, Int, String)? in
            guard let periods = course.schedule[weekday]?
                .sorted(by: { (order.firstIndex(of: $0) ?? .max) < (order.firstIndex(of: $1) ?? .max) }) else { return nil }
            for periodId in periods {
                if let start = parseHm(snapshot.periodTimes[periodId]?.start), start > nowMin {
                    return (course, start, periodId)
                }
            }
            return nil
        }
        if let pick = candidates.min(by: { $0.1 < $1.1 }) {
            return .nextToday(.init(
                course: pick.0,
                startTime: snapshot.periodTimes[pick.2]?.start ?? "",
                periodRange: pick.2
            ))
        }

        // 3. Tomorrow first: scan ahead up to 7 weekdays
        for offset in 1...7 {
            let target = ((weekday - 1 + offset) % 7) + 1
            let dayCourses = snapshot.courses.compactMap { course -> (SnapshotCourse, String)? in
                guard let periods = course.schedule[target]?
                    .sorted(by: { (order.firstIndex(of: $0) ?? .max) < (order.firstIndex(of: $1) ?? .max) }),
                      let firstPeriod = periods.first else { return nil }
                return (course, firstPeriod)
            }
            if let pick = dayCourses.min(by: {
                (order.firstIndex(of: $0.1) ?? .max) < (order.firstIndex(of: $1.1) ?? .max)
            }) {
                return .tomorrowFirst(.init(
                    course: pick.0,
                    startTime: snapshot.periodTimes[pick.1]?.start ?? "",
                    periodRange: pick.1
                ))
            }
        }

        return .noMoreClasses
    }

    // MARK: - Helpers

    /// Returns 1=Mon … 7=Sun. Pinned to the gregorian calendar so device
    /// locale calendars (e.g. ROC, Buddhist) don't shift weekday math
    /// against NTUST's gregorian-based schedule.
    static func weekdayFor(_ date: Date) -> Int {
        let raw = Calendar(identifier: .gregorian).component(.weekday, from: date)
        return raw == 1 ? 7 : raw - 1
    }

    static func minuteOfDayFor(_ date: Date) -> Int {
        let cal = Calendar(identifier: .gregorian)
        let h = cal.component(.hour, from: date)
        let m = cal.component(.minute, from: date)
        return h * 60 + m
    }

    static func parseHm(_ string: String?) -> Int? {
        guard let s = string else { return nil }
        let parts = s.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
