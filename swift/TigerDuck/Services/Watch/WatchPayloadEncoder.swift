import Foundation

enum WatchPayloadEncoder {

    static func encode(
        courses: [SDCourse],
        customNames: [String: String],
        accentHex: String,
        syncedAt: Date,
        loggedIn: Bool,
        languageTag: String?,
        visualPreset: VisualPreset,
        quietDays: Set<String> = []
    ) -> WatchSnapshot {
        let watchCourses = loggedIn
            ? courses.flatMap { flatten($0, customNames: customNames) }
            : []
        let syncedAtMs = Int64((syncedAt.timeIntervalSince1970 * 1000).rounded())
        return WatchSnapshot(
            courses: watchCourses,
            accentHex: accentHex,
            syncedAtMs: syncedAtMs,
            loggedIn: loggedIn,
            languageTag: languageTag,
            visualPreset: visualPreset,
            clockOverrideJSON: encodedClockOverride(),
            quietDays: quietDays
        )
    }

    private static func encodedClockOverride() -> String? {
        #if DEBUG
        guard let override = AppClock.currentOverride() else { return nil }
        guard let data = try? JSONEncoder().encode(override),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
        #else
        return nil
        #endif
    }

    private static func flatten(_ course: SDCourse, customNames: [String: String]) -> [WatchCourse] {
        let order = AppConstants.Periods.chronologicalOrder
        let skipped = Set(course.skippedDates)
        return course.schedule.flatMap { weekday, periodIds -> [WatchCourse] in
            let sorted = periodIds.sortedByPeriodOrder()
            return contiguousRuns(sorted, by: order).compactMap { run -> WatchCourse? in
                guard let first = run.first,
                      let last = run.last,
                      let startPeriod = TimetablePeriod.byId[first],
                      let endPeriod = TimetablePeriod.byId[last] else { return nil }
                let label = run.count > 1 ? "\(first)-\(last)" : first
                return WatchCourse(
                    id: "\(course.courseNo)-\(weekday)-\(first)",
                    courseNo: course.courseNo,
                    name: resolveDisplayName(course: course, customNames: customNames),
                    teacher: course.instructor,
                    classroom: course.classroom(weekday: weekday, periods: run),
                    colorHex: courseColorHex(course),
                    weekday: weekday,
                    startHHmm: startPeriod.startTime,
                    endHHmm: endPeriod.endTime,
                    periodLabel: label,
                    skippedDates: skipped.isEmpty ? nil : skipped
                )
            }
        }
        .sorted { ($0.weekday, $0.startHHmm) < ($1.weekday, $1.startHHmm) }
    }

    private static func contiguousRuns(_ periods: [String], by order: [String]) -> [[String]] {
        var runs: [[String]] = []
        var current: [String] = []
        var prevIndex = Int.min
        for period in periods {
            let idx = order.firstIndex(of: period) ?? Int.min
            if !current.isEmpty, idx == prevIndex + 1 {
                current.append(period)
            } else {
                if !current.isEmpty { runs.append(current) }
                current = [period]
            }
            prevIndex = idx
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    private static func resolveDisplayName(
        course: SDCourse,
        customNames: [String: String]
    ) -> String {
        if let alias = customNames[course.courseNo], !alias.isEmpty { return alias }
        if let alias = course.customName, !alias.isEmpty { return alias }
        return course.courseName
    }

    private static func courseColorHex(_ course: SDCourse) -> String {
        TigerDuckTheme.courseColorHex(for: course.courseNo)
    }
}
