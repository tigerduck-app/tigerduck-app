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
        quietDays: Set<String> = [],
        changes: CourseChanges = .empty
    ) -> WatchSnapshot {
        let watchCourses = loggedIn
            ? courses.flatMap { flatten($0, customNames: customNames, changes: changes) }
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

    private static func flatten(
        _ course: SDCourse, customNames: [String: String], changes: CourseChanges
    ) -> [WatchCourse] {
        let order = AppConstants.Periods.chronologicalOrder
        let skipped = Set(course.skippedDates)
        let changed = WidgetSnapshotBuilder.snapshotChanges(of: course, changes: changes)
        return course.schedule.flatMap { weekday, periodIds -> [WatchCourse] in
            func meeting(
                _ periods: [String], change: SnapshotCourseChange? = nil, classes: [String: [WatchCourse]]? = nil
            ) -> WatchCourse? {
                guard let first = periods.first,
                      let last = periods.last,
                      let startPeriod = TimetablePeriod.byId[first],
                      let endPeriod = TimetablePeriod.byId[last] else { return nil }
                return WatchCourse(
                    id: "\(course.courseNo)-\(weekday)-\(first)",
                    courseNo: course.courseNo,
                    name: resolveDisplayName(course: course, customNames: customNames),
                    teacher: course.instructor,
                    classroom: change?.room ?? course.classroom(weekday: weekday, periods: periods),
                    colorHex: courseColorHex(course),
                    weekday: weekday,
                    startHHmm: change?.start ?? startPeriod.startTime,
                    endHHmm: change?.end ?? endPeriod.endTime,
                    periodLabel: periods.count > 1 ? "\(first)-\(last)" : first,
                    skippedDates: skipped.isEmpty ? nil : skipped,
                    changes: classes,
                    dayChange: change.map { WatchCourseChange(cancelled: $0.cancelled, room: $0.room, start: $0.start, end: $0.end) }
                )
            }
            return contiguousRuns(periodIds.sortedByPeriodOrder(), by: order).compactMap { run -> WatchCourse? in
                let classes = Dictionary(
                    grouping: changed.filter { !$0.periods.isEmpty && run.contains($0.periods[0]) }, by: \.day
                ).mapValues { $0.compactMap { meeting($0.periods, change: $0) } }
                return meeting(run, classes: classes.isEmpty ? nil : classes)
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
